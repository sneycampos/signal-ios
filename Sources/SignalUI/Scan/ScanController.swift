import Foundation
import ARKit
import AVFoundation
import Observation
import RoomPlan
import SignalCore

enum ScanAvailability {
    case available
    case unsupportedDevice
    case cameraDenied

    static var current: ScanAvailability {
        #if DEBUG
        if ScanController.isFakeScanFailureEnabled { return .available }
        #endif
        guard RoomCaptureSession.isSupported else { return .unsupportedDevice }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return .cameraDenied
        default: return .available
        }
    }

    static func requestCamera() async -> Bool {
        #if DEBUG
        if ScanController.isFakeScanFailureEnabled ||
           ProcessInfo.processInfo.arguments.contains("-uitest-demo") {
            return true
        }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// Drives a multi-room RoomPlan session sharing one ARSession, so every room lands in the same
/// coordinate frame and the final world map can relocalize the AR view later.
@MainActor
@Observable
final class ScanController {
    enum Phase: Equatable {
        case scanning
        case processingRoom
        case finishing
        case failed(String)
    }

    struct Counts: Equatable {
        var walls = 0
        var doors = 0
        var windows = 0
        var objects = 0
    }

    #if DEBUG
    nonisolated static var isFakeScanFailureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-fake-scan-failure")
    }
    #endif

    private(set) var phase: Phase = .scanning
    private(set) var roomNumber = 1
    private(set) var counts = Counts()
    private(set) var routerMarked = false
    private(set) var roomsCaptured = 0
    var roomWarning: String?
    private(set) var canCompleteFromWarning = false

    @ObservationIgnored let arSession = ARSession()
    @ObservationIgnored private(set) var captureView: RoomCaptureView?
    @ObservationIgnored private var delegate: ScanDelegate?
    @ObservationIgnored private var rooms: [CapturedRoom] = []
    @ObservationIgnored private var routerMarker: simd_float3?
    @ObservationIgnored private var routerStory = 0
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var hadWallsInCurrentRoom = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var worldMap: Data?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var currentStory = 0
    @ObservationIgnored var onComplete: ((RoomPlanCapture, Data?) -> Void)?

    init() {
        #if DEBUG
        if Self.isFakeScanFailureEnabled { return }
        #endif
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        let scanDelegate = ScanDelegate(controller: self)
        view.captureSession.delegate = scanDelegate
        view.delegate = scanDelegate
        captureView = view
        delegate = scanDelegate
    }

    func start() {
        guard !cancelled else { return }
        #if DEBUG
        if Self.isFakeScanFailureEnabled {
            counts = Counts(walls: 4, doors: 1, windows: 1, objects: 0)
            return
        }
        #endif
        captureView?.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func markRouter() {
        guard let transform = arSession.currentFrame?.camera.transform else { return }
        routerMarker = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        routerStory = currentStory
        routerMarked = true
    }

    func nextRoom() {
        guard phase == .scanning else { return }
        #if DEBUG
        if Self.isFakeScanFailureEnabled {
            roomWarning = "Couldn't process Room \(roomNumber). Scan this room again with good light, moving the device slowly."
            scheduleFakeFailure()
            return
        }
        #endif
        finishing = false
        hadWallsInCurrentRoom = counts.walls > 0
        phase = .processingRoom
        captureView?.captureSession.stop(pauseARSession: false)
    }

    func finish() {
        guard phase == .scanning else { return }
        #if DEBUG
        if Self.isFakeScanFailureEnabled {
            triggerFakeFailure()
            return
        }
        #endif
        finishing = true
        hadWallsInCurrentRoom = counts.walls > 0
        phase = .finishing
        arSession.getCurrentWorldMap { [weak self] map, _ in
            let data = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor in
                guard let self, !self.cancelled, self.phase == .finishing else { return }
                self.worldMap = data
                self.captureView?.captureSession.stop(pauseARSession: false)
            }
        }
    }

    #if DEBUG
    func scheduleFakeFailure() {
        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, !self.cancelled else { return }
            self.triggerFakeFailure()
        }
    }

    func triggerFakeFailure() {
        guard !cancelled else { return }
        roomWarning = nil
        canCompleteFromWarning = false
        phase = .failed("Scanning stopped: Fake sensor failure. Close this scan and try again.")
    }
    #endif

    func dismissWarning() {
        roomWarning = nil
        canCompleteFromWarning = false
    }

    func completeWithCapturedRooms() {
        guard !cancelled, !rooms.isEmpty else { return }
        roomWarning = nil
        canCompleteFromWarning = false
        finishing = true
        phase = .finishing
        captureView?.captureSession.delegate = nil
        captureView?.delegate = nil
        captureView?.captureSession.stop(pauseARSession: true)
        processingTask?.cancel()
        processingTask = Task {
            await complete()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        processingTask?.cancel()
        processingTask = nil
        onComplete = nil
        captureView?.captureSession.delegate = nil
        captureView?.delegate = nil
        captureView?.captureSession.stop(pauseARSession: true)
        arSession.pause()
        rooms.removeAll()
        worldMap = nil
    }

    var hasCapturedAnything: Bool { roomsCaptured > 0 || counts.walls > 0 }

    func interrupted() {
        guard !cancelled else { return }
        processingTask?.cancel()
        processingTask = nil
        roomWarning = nil
        canCompleteFromWarning = false
        phase = .failed(roomsCaptured > 0
            ? "Scanning was interrupted. You can save the rooms already captured or close and try again."
            : "Scanning was interrupted. Close this scan and try again.")
        captureView?.captureSession.delegate = nil
        captureView?.delegate = nil
        captureView?.captureSession.stop(pauseARSession: true)
        arSession.pause()
    }

    // MARK: Delegate events

    fileprivate func didUpdate(_ room: CapturedRoom) {
        guard !cancelled, captureView?.captureSession.delegate != nil, phase == .scanning else { return }
        currentStory = room.story
        counts = Counts(walls: room.walls.count, doors: room.doors.count + room.openings.count, windows: room.windows.count, objects: room.objects.count)
    }

    fileprivate func didEnd(with data: CapturedRoomData, error: String?) {
        guard !cancelled, captureView?.captureSession.delegate != nil else { return }
        if case .failed = phase { return }
        if let error {
            roomWarning = nil
            canCompleteFromWarning = false
            phase = .failed(roomsCaptured > 0
                ? "Scanning stopped: \(error). You can save the rooms already captured or close and try again."
                : "Scanning stopped: \(error). Close this scan and try again.")
            arSession.pause()
            return
        }
        guard phase == .processingRoom || phase == .finishing else {
            roomWarning = nil
            canCompleteFromWarning = false
            phase = .failed(roomsCaptured > 0
                ? "Scanning was interrupted. You can save the rooms already captured or close and try again."
                : "Scanning was interrupted. Close this scan and try again.")
            arSession.pause()
            return
        }
        processingTask = Task {
            var roomBuildFailed = false
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                guard !Task.isCancelled, !cancelled else { return }
                rooms.append(room)
                roomsCaptured = rooms.count
            } catch {
                guard !Task.isCancelled, !cancelled else { return }
                SignalDebugLogger.shared.log("Discarded room: \(error.localizedDescription)", category: "Scan")
                if rooms.isEmpty && finishing {
                    phase = .failed("Couldn't build the plan. Try again with more light, moving the device slowly.")
                    arSession.pause()
                    return
                }
                roomBuildFailed = true
            }
            guard !Task.isCancelled, !cancelled else { return }
            if finishing && (!roomBuildFailed || !hadWallsInCurrentRoom) {
                await complete()
            } else {
                let wasFinishing = finishing
                finishing = false
                roomNumber = rooms.count + 1
                counts = Counts()
                phase = .scanning
                if roomBuildFailed {
                    canCompleteFromWarning = wasFinishing && !rooms.isEmpty
                    roomWarning = canCompleteFromWarning
                        ? "Couldn't process Room \(roomNumber). You can scan this room again or save the rooms already captured."
                        : "Couldn't process Room \(roomNumber). Scan this room again with good light, moving the device slowly."
                }
                captureView?.captureSession.run(configuration: RoomCaptureSession.Configuration())
            }
        }
    }

    private func complete() async {
        let capture: RoomPlanCapture
        if rooms.count > 1 {
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                guard !Task.isCancelled, !cancelled else { return }
                capture = RoomPlanExtraction.capture(from: structure, routerMarker: routerMarker, routerStory: routerStory)
            } catch {
                guard !Task.isCancelled, !cancelled else { return }
                SignalDebugLogger.shared.log("Failed to merge rooms: \(error.localizedDescription)", category: "Scan")
                capture = merged(rooms)
            }
        } else if let room = rooms.first {
            capture = RoomPlanExtraction.capture(from: room, routerMarker: routerMarker)
        } else {
            phase = .failed("No rooms were captured.")
            return
        }
        guard !Task.isCancelled, !cancelled else { return }
        arSession.pause()
        let completion = onComplete
        onComplete = nil
        completion?(capture, worldMap)
    }

    /// Fallback when StructureBuilder fails: rooms already share world coordinates.
    private func merged(_ rooms: [CapturedRoom]) -> RoomPlanCapture {
        var result = RoomPlanCapture(surfaces: [])
        for (roomIndex, room) in rooms.enumerated() {
            let part = RoomPlanExtraction.capture(from: room, routerMarker: nil)
            let prefix = "r\(roomIndex)_"
            result.surfaces += part.surfaces.map { s in
                RoomPlanRawSurface(
                    id: prefix + s.id,
                    p1: s.p1,
                    p2: s.p2,
                    height: s.height,
                    thickness: s.thickness,
                    category: s.category,
                    parentId: s.parentId.map { prefix + $0 },
                    isOpen: s.isOpen,
                    story: s.story
                )
            }
            result.objects += part.objects.map { o in
                RoomPlanRawObject(
                    id: prefix + o.id,
                    position: o.position,
                    dimensions: o.dimensions,
                    category: o.category,
                    yaw: o.yaw,
                    story: o.story
                )
            }
            result.floors += part.floors
            result.sections += part.sections
            result.floorY = [result.floorY, part.floorY].compactMap { $0 }.min()
        }
        result.routerMarker = routerMarker.map { SIMD2($0.x, $0.z) }
        result.routerMarkerStory = routerStory
        return result
    }
}

/// RoomPlan calls delegates from its own queues; hop to the main actor explicitly.
@objc(SignalScanDelegate)
final class ScanDelegate: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, @unchecked Sendable {
    weak var controller: ScanController?

    @MainActor
    init(controller: ScanController) {
        self.controller = controller
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in self?.controller?.didUpdate(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        let message = error.map { String(describing: $0) }
        Task { @MainActor [weak self] in
            if let message { SignalDebugLogger.shared.log("Session ended with error: \(message)", category: "Scan") }
            self?.controller?.didEnd(with: data, error: message)
        }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {}
}
