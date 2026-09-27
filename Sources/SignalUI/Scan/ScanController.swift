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
        guard RoomCaptureSession.isSupported else { return .unsupportedDevice }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return .cameraDenied
        default: return .available
        }
    }

    static func requestCamera() async -> Bool {
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

    private(set) var phase: Phase = .scanning
    private(set) var roomNumber = 1
    private(set) var counts = Counts()
    private(set) var routerMarked = false
    private(set) var roomsCaptured = 0

    @ObservationIgnored let arSession = ARSession()
    @ObservationIgnored private(set) var captureView: RoomCaptureView!
    @ObservationIgnored private var delegate: ScanDelegate!
    @ObservationIgnored private var rooms: [CapturedRoom] = []
    @ObservationIgnored private var routerMarker: simd_float3?
    @ObservationIgnored private var routerStory = 0
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var worldMap: Data?
    @ObservationIgnored var onComplete: ((RoomPlanCapture, Data?) -> Void)?

    init() {
        captureView = RoomCaptureView(frame: .zero, arSession: arSession)
        delegate = ScanDelegate(controller: self)
        captureView.captureSession.delegate = delegate
        captureView.delegate = delegate
    }

    func start() {
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func markRouter() {
        guard let transform = arSession.currentFrame?.camera.transform else { return }
        routerMarker = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        routerStory = rooms.last?.story ?? 0
        routerMarked = true
    }

    func nextRoom() {
        guard phase == .scanning else { return }
        finishing = false
        phase = .processingRoom
        captureView.captureSession.stop(pauseARSession: false)
    }

    func finish() {
        guard phase == .scanning else { return }
        finishing = true
        phase = .finishing
        arSession.getCurrentWorldMap { [weak self] map, _ in
            let data = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor in
                guard let self else { return }
                self.worldMap = data
                self.captureView.captureSession.stop(pauseARSession: false)
            }
        }
    }

    func cancel() {
        cancelled = true
        captureView.captureSession.stop(pauseARSession: true)
        arSession.pause()
    }

    var hasCapturedAnything: Bool { roomsCaptured > 0 || counts.walls > 0 }

    // MARK: Delegate events

    fileprivate func didUpdate(_ room: CapturedRoom) {
        counts = Counts(walls: room.walls.count, doors: room.doors.count + room.openings.count, windows: room.windows.count, objects: room.objects.count)
    }

    fileprivate func didEnd(with data: CapturedRoomData, error: (any Error)?) {
        guard !cancelled else { return }
        Task {
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                rooms.append(room)
                roomsCaptured = rooms.count
            } catch {
                if rooms.isEmpty && finishing {
                    phase = .failed("Couldn't build the plan. Try again with more light, moving the iPhone slowly.")
                    return
                }
                SignalDebugLogger.shared.log("Discarded room: \(error.localizedDescription)", category: "Scan")
            }
            if finishing {
                await complete()
            } else {
                roomNumber = rooms.count + 1
                counts = Counts()
                phase = .scanning
                captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
            }
        }
    }

    private func complete() async {
        let capture: RoomPlanCapture
        if rooms.count > 1 {
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                capture = RoomPlanExtraction.capture(from: structure, routerMarker: routerMarker, routerStory: routerStory)
            } catch {
                SignalDebugLogger.shared.log("Failed to merge rooms: \(error.localizedDescription)", category: "Scan")
                capture = merged(rooms)
            }
        } else if let room = rooms.first {
            capture = RoomPlanExtraction.capture(from: room, routerMarker: routerMarker)
        } else {
            phase = .failed("No rooms were captured.")
            return
        }
        arSession.pause()
        onComplete?(capture, worldMap)
    }

    /// Fallback when StructureBuilder fails: rooms already share world coordinates.
    private func merged(_ rooms: [CapturedRoom]) -> RoomPlanCapture {
        var result = RoomPlanCapture(surfaces: [])
        for room in rooms {
            let part = RoomPlanExtraction.capture(from: room, routerMarker: nil)
            result.surfaces += part.surfaces
            result.objects += part.objects
            result.floors += part.floors
            result.sections += part.sections
            result.floorY = min(result.floorY ?? .greatestFiniteMagnitude, part.floorY ?? .greatestFiniteMagnitude)
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
            self?.controller?.didEnd(with: data, error: nil)
        }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {}
}
