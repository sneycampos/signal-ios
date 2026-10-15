import Foundation
import Observation
import CoreGraphics
import simd

public enum MapViewMode: String, CaseIterable, Sendable, Identifiable {
    case plan
    case perspective

    public var id: String { rawValue }
}

public enum MapSelection: Equatable, Sendable {
    case wall(String)
    case accessPoint(String)
    case room(String)
}

public enum CanvasTool: Equatable, Sendable {
    case normal
    case placeRouter
    case addMeasurement
}

public enum WallScope: String, CaseIterable, Sendable, Identifiable {
    case single
    case sameMaterial
    case allExterior
    case allInterior

    public var id: String { rawValue }
}

public struct ToastMessage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let offersUndo: Bool
}

/// Everything the UI shows about one point of the plan.
public struct ProbeReading: Equatable, Sendable {
    public let point: SIMD2<Float>
    public let floor: Int
    public let rssi: Float
    public let grade: SignalGrade
    public let link: LinkEstimate
    public let budget: LinkBudget?
    public let servingAccessPoint: RFAccessPoint?
    public let backhaul: BackhaulLink?
    /// Throughput after the backhaul bottleneck (Mbps).
    public let effectiveThroughputMbps: Float
    /// Internet speed a device can expect here, when the plan speed is known.
    public let internetMbps: Float?
    public let roomName: String?
}

public struct OptimizerComparison: Equatable, Sendable {
    public let projectID: String
    public let floor: Int
    public let proposal: PlacementProposal
    public let band: RFBand
    public let before: CoverageSummary
    public let after: CoverageSummary
    public let roomsBefore: [RoomCoverage]
    public let roomsAfter: [RoomCoverage]
    public let satellitesToAdd: Int
    public let satellitesToRemove: Int
    public let isAlreadyOptimal: Bool
}

public enum OptimizerState: Equatable, Sendable {
    case idle
    case running(progress: Double)
    case ready(OptimizerComparison)
    case failed(String)
}

struct ImageBox: @unchecked Sendable {
    let image: CGImage?
}

/// Heatmap thumbnail and coverage for the projects list.
public struct ProjectPreview: @unchecked Sendable {
    public let project: FloorplanProject
    public let heatmap: CGImage?
    public let coverage: Float

    nonisolated static func make(_ project: FloorplanProject) -> ProjectPreview {
        let band = project.profile.planningBand
        let model = PropagationModel(walls: project.walls, band: band, calibration: project.calibration, floorHeight: project.profile.floorHeight)
        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.15, maxCells: 8_000)
        let mask = InteriorMask(grid: grid, polygons: project.rooms(onFloor: 0).map(\.polygon))
        let field = SignalFieldGenerator.compute(model: model, accessPoints: project.accessPoints, floor: 0, mask: mask, scale: SignalScale(profile: project.profile))
        return ProjectPreview(project: project, heatmap: field.flatMap(HeatmapImage.make), coverage: field?.coverage.coveredPercent ?? 0)
    }
}

@MainActor
@Observable
public final class FloorplanViewModel {
    // MARK: Projects

    @ObservationIgnored let store: ProjectStore
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var previews: [String: ProjectPreview] = [:]
    public private(set) var demoPreview: ProjectPreview?
    public private(set) var project: FloorplanProject?
    public private(set) var hasWorldMap = false

    // MARK: View state

    public var floor: Int = 0
    public var viewMode: MapViewMode = .plan
    public var heatmapOpacity: Double = 0.85
    public var showFurniture = false
    public var showRays = true
    public var tool: CanvasTool = .normal
    public var selection: MapSelection?
    public private(set) var draggingAccessPointId: String?

    // MARK: Results

    public private(set) var field: SignalField?
    public private(set) var heatmapImage: CGImage?
    public private(set) var coverageContours: [SIMD4<Float>] = []
    public private(set) var weakContours: [SIMD4<Float>] = []
    public private(set) var coverage: CoverageSummary = .empty
    public private(set) var roomCoverage: [RoomCoverage] = []
    public private(set) var backhaul: [String: BackhaulLink] = [:]
    public private(set) var probe: ProbeReading?
    public var isComputing: Bool { isComputingField || isComputingBackhaul }
    public var optimizer: OptimizerState = .idle
    public private(set) var canUndo = false
    public var toast: ToastMessage?
    public var errorMessage: String?
    /// Set after a scan so the map asks for the equipment details once.
    public var shouldPresentSetup = false

    // MARK: Private

    private var isComputingField = false
    private var isComputingBackhaul = false
    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private var computeGeneration = 0
    @ObservationIgnored private var liveInFlight = false
    @ObservationIgnored private var livePending = false
    @ObservationIgnored private var backhaulGeneration = 0
    #if DEBUG
    public private(set) var heatmapPublishCount = 0
    public private(set) var liveHeatmapPublishCount = 0
    #endif
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var optimizerTask: Task<Void, Never>?
    @ObservationIgnored private var optimizerToken: CancellationToken?
    @ObservationIgnored private var undoStack: [FloorplanProject] = []
    @ObservationIgnored private var dragStart: FloorplanProject?
    @ObservationIgnored private var cachedModel: (key: String, model: PropagationModel)?
    @ObservationIgnored private var optimizerSnapshot: FloorplanProject?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var backhaulKey: FloorplanProject?
    @ObservationIgnored private var backhaulTask: Task<Void, Never>?

    public init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    // MARK: - Lifecycle

    public func start() async {
        do {
            if let migrated = try await store.migrateLegacyScanIfNeeded() {
                SignalDebugLogger.shared.log("Migrated legacy scan to project \(migrated.id)", category: "Store")
            }
        } catch {
            errorMessage = "Couldn't migrate the saved scan. The original scan is preserved. \(error.localizedDescription)"
        }
        await refreshProjects()
    }

    public func refreshProjects() async {
        projects = await store.list()
        let ids = Set(projects.prefix(24).map(\.id))
        previews = previews.filter { ids.contains($0.key) }
        if demoPreview == nil {
            demoPreview = await Task.detached(priority: .utility) { ProjectPreview.make(DefaultApartmentFixture.makeProject()) }.value
        }
        for summary in projects.prefix(24) {
            if let existing = previews[summary.id], existing.project.updatedAt >= summary.updatedAt { continue }
            guard let loaded = try? await store.load(id: summary.id) else { continue }
            previews[summary.id] = await Task.detached(priority: .utility) { ProjectPreview.make(loaded) }.value
        }
    }

    public var isProjectOpen: Bool { project != nil }
    public var hasUnsavedChanges: Bool { dirty }
    public var scale: SignalScale { SignalScale(profile: project?.profile ?? NetworkProfile()) }
    public var band: RFBand { project?.selectedBand ?? .five }

    public func open(id: String) async {
        do {
            let loaded = try await store.load(id: id)
            let hasMap = await store.worldMap(for: id) != nil
            await present(loaded, hasWorldMap: hasMap)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func openDemo() async {
        await present(DefaultApartmentFixture.makeProject())
    }

    #if DEBUG
    public func prepareUITestDemo() async {
        let base = DefaultApartmentFixture.makeProject()
        var rooms = base.rooms
        rooms.append(
            RoomInfo(
                id: "room_upstairs",
                name: "Upstairs bedroom",
                kind: .bedroom,
                polygon: [SIMD2(0, 0), SIMD2(7, 0), SIMD2(7, 6), SIMD2(0, 6)],
                floor: 1
            )
        )
        let saved = FloorplanProject(
            id: "uitest-saved",
            name: "Saved apartment",
            width: base.width,
            depth: base.depth,
            walls: base.walls,
            accessPoints: base.accessPoints,
            rooms: rooms,
            probe: base.probe,
            floorCount: 2
        )
        try? await store.save(saved)
        await start()
        await openDemo()
    }
    #endif

    @discardableResult
    private func present(_ newProject: FloorplanProject, hasWorldMap: Bool = false) async -> Bool {
        guard await flushSave(), !Task.isCancelled else { return false }
        cancelOptimizer()
        backhaulTask?.cancel()
        project = newProject
        self.hasWorldMap = hasWorldMap
        dirty = false
        draggingAccessPointId = nil
        dragStart = nil
        floor = min(newProject.probeFloor, newProject.floorCount - 1)
        selection = nil
        tool = .normal
        undoStack = []
        canUndo = false
        optimizer = .idle
        field = nil
        heatmapImage = nil
        #if DEBUG
        heatmapPublishCount = 0
        liveHeatmapPublishCount = 0
        #endif
        coverage = .empty
        roomCoverage = []
        coverageContours = []
        weakContours = []
        cachedModel = nil
        backhaulKey = nil
        backhaul = [:]
        refreshInstant()
        recompute(quality: .full)
        return true
    }

    public func close() async {
        guard await flushSave() else { return }
        cancelOptimizer()
        computeTask?.cancel()
        backhaulTask?.cancel()
        computeGeneration += 1
        backhaulGeneration += 1
        liveInFlight = false
        livePending = false
        #if DEBUG
        heatmapPublishCount = 0
        liveHeatmapPublishCount = 0
        #endif
        isComputingField = false
        isComputingBackhaul = false
        project = nil
        hasWorldMap = false
        draggingAccessPointId = nil
        dragStart = nil
        field = nil
        heatmapImage = nil
        probe = nil
        coverage = .empty
        roomCoverage = []
        coverageContours = []
        weakContours = []
        backhaul = [:]
        selection = nil
        Task { await refreshProjects() }
    }

    public func delete(id: String) async {
        if project?.id == id {
            saveTask?.cancel()
            await saveTask?.value
        }
        do { try await store.delete(id: id) }
        catch {
            errorMessage = "Couldn't delete the project: \(error.localizedDescription)"
            return
        }
        if project?.id == id {
            saveTask?.cancel()
            computeTask?.cancel()
            backhaulTask?.cancel()
            computeGeneration += 1
            backhaulGeneration += 1
            liveInFlight = false
            livePending = false
            #if DEBUG
            heatmapPublishCount = 0
            liveHeatmapPublishCount = 0
            #endif
            cancelOptimizer()
            dirty = false
            project = nil
            hasWorldMap = false
            field = nil
            heatmapImage = nil
            probe = nil
            backhaul = [:]
            coverage = .empty
            roomCoverage = []
            coverageContours = []
            weakContours = []
            isComputingField = false
            isComputingBackhaul = false
        }
        await refreshProjects()
    }

    public func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(undoable: false) { $0.name = trimmed }
    }

    // MARK: - Creating from a scan

    public func createProject(from capture: RoomPlanCapture, worldMap: Data?) async {
        var profile = NetworkProfile()
        profile.construction = .masonry
        let conversion = Task.detached(priority: .userInitiated) { RoomPlanConverter.convert(capture, profile: profile) }
        let converted = await withTaskCancellationHandler {
            await conversion.value
        } onCancel: { conversion.cancel() }
        guard !Task.isCancelled else { return }
        guard !converted.walls.isEmpty else {
            errorMessage = "No walls were detected. Point the camera slowly at walls and corners, with good lighting."
            return
        }
        let firstRoom = converted.rooms.filter { $0.floor == converted.routerFloor }.max { $0.area < $1.area }
        let fallback = firstRoom?.labelPoint ?? SIMD2<Float>(converted.width * 0.5, converted.depth * 0.5)
        let routerPosition = RoomPlanConverter.pushAwayFromWalls(converted.routerPosition ?? fallback, walls: converted.walls)
        let router = RFAccessPoint(name: "Router", position: routerPosition, floor: converted.routerFloor, isLocked: converted.routerPosition != nil)
        let name = "Scan of \(Date().formatted(date: .abbreviated, time: .shortened))"
        let newProject = FloorplanProject(
            name: name,
            width: converted.width,
            depth: converted.depth,
            walls: converted.walls,
            accessPoints: [router],
            rooms: converted.rooms,
            furniture: converted.furniture,
            profile: profile,
            probe: (converted.rooms.first?.labelPoint ?? fallback) + SIMD2<Float>(0.6, 0.4),
            probeFloor: converted.routerFloor,
            worldAlignment: converted.alignment,
            floorCount: converted.floorCount
        )
        do {
            try Task.checkCancellation()
            try await store.save(newProject)
            try Task.checkCancellation()
            var savedWorldMap = false
            if let worldMap {
                do {
                    try await store.saveWorldMap(worldMap, for: newProject.id)
                    savedWorldMap = true
                } catch {
                    errorMessage = "Your plan was saved, but its AR environment map couldn't be saved. Scan again to enable AR. \(error.localizedDescription)"
                }
            }
            try Task.checkCancellation()
            guard await present(newProject, hasWorldMap: savedWorldMap) else { return }
            if converted.routerPosition == nil {
                tool = .placeRouter
            }
            shouldPresentSetup = true
            await refreshProjects()
            SignalDebugLogger.shared.log("Created project: \(converted.walls.count) segments, \(converted.rooms.count) rooms, \(converted.floorCount) floor(s)", category: "Scan")
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Import / export

    public func importProject(from url: URL) async {
        if let existingID = await store.isExistingProjectFile(url) {
            await open(id: existingID)
            return
        }
        do {
            let imported = try await store.importProject(from: url)
            await refreshProjects()
            let hasMap = await store.worldMap(for: imported.id) != nil
            guard await present(imported, hasWorldMap: hasMap) else { return }
            toast = ToastMessage(text: "Project imported.", offersUndo: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func exportFileURL() async -> URL? {
        guard let project else { return nil }
        return try? await store.exportFile(for: project)
    }

    public func webExportData() -> Data? {
        guard let project else { return nil }
        return try? SignalDataExporter.exportJSON(SignalDataExporter.document(from: project))
    }

    public func worldMapData() async -> Data? {
        guard let id = project?.id else { return nil }
        return await store.worldMap(for: id)
    }

    // MARK: - Editing

    public func setBand(_ band: RFBand) {
        guard project?.selectedBand != band else { return }
        field = nil
        heatmapImage = nil
        coverage = .empty
        roomCoverage = []
        coverageContours = []
        weakContours = []
        mutate(undoable: false, recompute: .full) { $0.selectedBand = band }
    }

    public func setFloor(_ newFloor: Int) {
        guard let project, newFloor >= 0, newFloor < project.floorCount, newFloor != floor else { return }
        floor = newFloor
        let rooms = project.rooms(onFloor: newFloor)
        if !rooms.isEmpty, !rooms.contains(where: { $0.contains(project.probe) }) {
            self.project?.probe = rooms[0].labelPoint
        }
        self.project?.probeFloor = newFloor
        invalidateOptimizer()
        selection = nil
        field = nil
        heatmapImage = nil
        coverage = .empty
        roomCoverage = []
        coverageContours = []
        weakContours = []
        refreshInstant()
        recompute(quality: .full)
    }

    public func accessPoint(id: String) -> RFAccessPoint? { project?.accessPoints.first { $0.id == id } }
    public func wall(id: String) -> RFWallSegment? { project?.walls.first { $0.id == id } }
    public func room(id: String) -> RoomInfo? { project?.rooms.first { $0.id == id } }

    public func beginDrag(accessPointId: String) {
        guard draggingAccessPointId == nil else { return }
        draggingAccessPointId = accessPointId
        dragStart = project
    }

    /// Moves an AP, keeping it inside the home, off walls and outside furniture.
    public func moveAccessPoint(id: String, to target: SIMD2<Float>) {
        guard let project, let index = project.accessPoints.firstIndex(where: { $0.id == id }) else { return }
        let apFloor = project.accessPoints[index].floor
        guard let position = validPosition(target, floor: apFloor, previous: project.accessPoints[index].position) else { return }
        self.project?.accessPoints[index].position = position
        if !project.isDemo { dirty = true }
        invalidateOptimizer()
        refreshInstant()
        recompute(quality: draggingAccessPointId == nil ? .full : .live)
        if draggingAccessPointId == nil { scheduleSave() }
    }

    public func endDrag() {
        guard draggingAccessPointId != nil else { return }
        draggingAccessPointId = nil
        if let start = dragStart, start.accessPoints != project?.accessPoints {
            pushUndo(start)
        }
        dragStart = nil
        refreshInstant()
        recompute(quality: .full)
        scheduleSave()
    }

    public func nudgeAccessPoint(id: String, by delta: SIMD2<Float>) {
        guard let ap = accessPoint(id: id) else { return }
        if let project { pushUndo(project) }
        moveAccessPoint(id: id, to: ap.position + delta)
    }

    public func addSatellite(at position: SIMD2<Float>? = nil) {
        guard let project else { return }
        let count = project.satellites.count + 1
        let target = position ?? suggestedSatellitePosition()
        let resolved = validPosition(target, floor: floor, previous: nil) ?? target
        let satellite = RFAccessPoint(name: "Satellite \(count)", position: resolved, isSatellite: true, floor: floor)
        mutate(recompute: .full) { $0.accessPoints.append(satellite) }
        selection = .accessPoint(satellite.id)
    }

    public func removeAccessPoint(id: String) {
        guard let ap = accessPoint(id: id), ap.isSatellite else { return }
        if selection == .accessPoint(id) { selection = nil }
        mutate(recompute: .full) { $0.accessPoints.removeAll { $0.id == id } }
        toast = ToastMessage(text: "\(ap.name) removed.", offersUndo: true)
    }

    public func updateAccessPoint(id: String, _ change: (inout RFAccessPoint) -> Void) {
        guard let project, let index = project.accessPoints.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.accessPoints[index]
        var ap = previous
        change(&ap)
        let trimmed = ap.name.trimmingCharacters(in: .whitespacesAndNewlines)
        ap.name = trimmed.isEmpty ? previous.name : trimmed
        if ap.floor != previous.floor {
            ap.floor = max(0, min(project.floorCount - 1, ap.floor))
            ap.position = validPosition(ap.position, floor: ap.floor, previous: nil) ?? ap.position
        }
        guard ap != previous else { return }
        let rfChanged = ap.position != previous.position
            || ap.txPower != previous.txPower
            || ap.isSatellite != previous.isSatellite
            || ap.isActive != previous.isActive
            || ap.floor != previous.floor
            || ap.backhaul != previous.backhaul
        mutate(recompute: rfChanged ? .full : .none) { $0.accessPoints[index] = ap }
    }

    public func updateRoom(id: String, name: String? = nil, kind: RoomKind? = nil) {
        guard let project, let index = project.rooms.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.rooms[index]
        var room = previous
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { room.name = trimmed }
        }
        if let kind { room.kind = kind }
        guard room != previous else { return }
        mutate(recompute: .none) { $0.rooms[index] = room }
        if let covIndex = roomCoverage.firstIndex(where: { $0.id == id }) {
            let old = roomCoverage[covIndex]
            roomCoverage[covIndex] = RoomCoverage(id: old.id, name: room.name, kind: room.kind, labelPoint: old.labelPoint, summary: old.summary, grade: old.grade, servingAccessPointId: old.servingAccessPointId)
        }
    }

    public func walls(for scope: WallScope, like wallId: String) -> [String] {
        guard let project, let reference = wall(id: wallId) else { return [] }
        let structural = project.walls.filter { $0.floor == reference.floor && $0.kind == reference.kind }
        switch scope {
        case .single: return [wallId]
        case .sameMaterial: return structural.filter { $0.material.id == reference.material.id }.map(\.id)
        case .allExterior: return structural.filter(\.isExterior).map(\.id)
        case .allInterior: return structural.filter { !$0.isExterior }.map(\.id)
        }
    }

    public func setMaterial(_ material: RFMaterial, forWalls ids: [String]) {
        var targets = Set(ids)
        if let project {
            let groups = project.walls.filter { targets.contains($0.id) && $0.groupId != 0 }.map { ($0.groupId, $0.floor) }
            targets.formUnion(project.walls.filter { wall in groups.contains { $0.0 == wall.groupId && $0.1 == wall.floor } }.map(\.id))
        }
        guard !targets.isEmpty else { return }
        mutate(recompute: .full, invalidatesModel: true) { project in
            for i in project.walls.indices where targets.contains(project.walls[i].id) {
                project.walls[i].material = material
                project.walls[i].isMaterialAuto = false
            }
        }
    }

    public func updateProfile(_ change: (inout NetworkProfile) -> Void) {
        guard let project else { return }
        var profile = project.profile
        change(&profile)
        profile.normalizeChannelWidths()
        guard profile != project.profile else { return }
        var a = profile
        var b = project.profile
        a.internetPlanMbps = 0
        b.internetPlanMbps = 0
        let rfChanged = a != b
        let constructionChanged = profile.construction != project.profile.construction
        mutate(undoable: rfChanged, recompute: rfChanged ? .full : .none, invalidatesModel: rfChanged) { p in
            p.profile = profile
            if !profile.supportedBands.contains(p.selectedBand) { p.selectedBand = profile.planningBand }
            if constructionChanged {
                for i in p.walls.indices where p.walls[i].isMaterialAuto && p.walls[i].kind == .wall {
                    p.walls[i].material = p.walls[i].isExterior ? profile.construction.exteriorMaterial : profile.construction.interiorMaterial
                }
            }
        }
    }

    // MARK: - Canvas interaction

    /// Handles a tap on the plan according to the active tool.
    public func handleTap(at point: SIMD2<Float>, wallTolerance: Float) {
        guard let project else { return }
        switch tool {
        case .placeRouter:
            tool = .normal
            guard let routerIndex = project.accessPoints.firstIndex(where: { !$0.isSatellite }),
                  let position = validPosition(point, floor: floor, previous: nil) else { return }
            let currentFloor = floor
            mutate(recompute: .full) { p in
                p.accessPoints[routerIndex].position = position
                p.accessPoints[routerIndex].floor = currentFloor
                p.accessPoints[routerIndex].isLocked = true
            }
        case .addMeasurement:
            placeProbe(at: point)
        case .normal:
            if let wall = hitTestWall(near: point, tolerance: wallTolerance) {
                selection = .wall(wall.id)
            } else {
                placeProbe(at: point)
                selection = nil
            }
        }
    }

    public func placeProbe(at point: SIMD2<Float>) {
        guard let project else { return }
        let clamped = SIMD2<Float>(max(0, min(project.width, point.x)), max(0, min(project.depth, point.y)))
        self.project?.probe = clamped
        self.project?.probeFloor = floor
        refreshInstant()
        scheduleSave()
    }

    public func hitTestWall(near point: SIMD2<Float>, tolerance: Float) -> RFWallSegment? {
        guard let project else { return nil }
        var best: RFWallSegment?
        var bestDistance = tolerance
        for wall in project.walls where wall.floor == floor && wall.isActive {
            let d = wall.distance(to: point)
            if d < bestDistance {
                bestDistance = d
                best = wall
            }
        }
        return best
    }

    // MARK: - Optimizer

    public func runOptimizer(satellites: SatelliteCountOption, lockRouter: Bool) {
        guard let project else { return }
        cancelOptimizer()
        let token = CancellationToken()
        optimizerToken = token
        optimizer = .running(progress: 0)
        let request = PlacementRequest(
            walls: project.walls,
            rooms: project.rooms,
            accessPoints: project.accessPoints,
            profile: project.profile,
            calibration: project.calibration,
            width: project.width,
            depth: project.depth,
            floor: floor,
            satellites: satellites,
            lockRouter: lockRouter,
            band: project.selectedBand
        )
        let snapshot = project
        optimizerSnapshot = snapshot
        let currentFloor = floor
        let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, !token.isCancelled, case .running = self.optimizer else { return }
                self.optimizer = .running(progress: value)
            }
        }
        optimizerTask = Task { [weak self] in
            let comparison = await Task.detached(priority: .userInitiated) { () -> OptimizerComparison? in
                let proposal = PlacementOptimizer.optimize(request, token: token, progress: reportProgress)
                guard let proposal, !token.isCancelled else { return nil }
                return FloorplanViewModel.compare(project: snapshot, proposal: proposal, floor: currentFloor)
            }.value
            guard let self, !token.isCancelled, self.optimizerMatches(snapshot), self.floor == currentFloor else { return }
            if let comparison {
                self.optimizer = .ready(comparison)
            } else {
                self.optimizer = .failed("Couldn't find valid positions. Check that the plan has rooms and open space.")
            }
        }
    }

    public func cancelOptimizer() {
        optimizerToken?.cancel()
        optimizerTask?.cancel()
        optimizerToken = nil
        optimizerTask = nil
        if case .running = optimizer { optimizer = .idle }
    }

    public func discardOptimizerResult() {
        cancelOptimizer()
        optimizer = .idle
    }

    private func invalidateOptimizer() {
        cancelOptimizer()
        optimizer = .idle
        optimizerSnapshot = nil
    }

    /// Probe movement does not change the placement problem or invalidate a proposal.
    private func optimizerMatches(_ snapshot: FloorplanProject) -> Bool {
        guard var current = project else { return false }
        current.probe = snapshot.probe
        current.probeFloor = snapshot.probeFloor
        return current == snapshot
    }

    public func applyOptimizerResult() {
        guard case .ready(let comparison) = optimizer, let snapshot = optimizerSnapshot, optimizerMatches(snapshot),
              project?.id == comparison.projectID, floor == comparison.floor else { invalidateOptimizer(); return }
        guard !comparison.isAlreadyOptimal else { optimizer = .idle; return }
        let proposal = comparison.proposal
        let currentFloor = floor
        mutate(recompute: .full) { p in
            p.accessPoints = Self.applyingProposal(proposal, to: p.accessPoints, floor: currentFloor)
        }
        optimizer = .idle
        toast = ToastMessage(text: "Positions applied.", offersUndo: true)
    }

    nonisolated static func applyingProposal(
        _ proposal: PlacementProposal,
        to accessPoints: [RFAccessPoint],
        floor currentFloor: Int
    ) -> [RFAccessPoint] {
        var result = accessPoints
        if let routerIndex = result.firstIndex(where: { !$0.isSatellite && $0.isActive }) ?? result.firstIndex(where: { !$0.isSatellite }) {
            if result[routerIndex].position != proposal.routerPosition {
                result[routerIndex].isLocked = false
            }
            result[routerIndex].position = proposal.routerPosition
        }
        let existing = result
            .filter { $0.isSatellite && $0.floor == currentFloor && $0.isActive }
            .sorted { ($0.isLocked ? 0 : 1, $0.backhaul == .wired ? 0 : 1) < ($1.isLocked ? 0 : 1, $1.backhaul == .wired ? 0 : 1) }
        let keepCount = min(existing.count, proposal.satellitePositions.count)
        let kept = Array(existing.prefix(keepCount))
        var unassignedSlots = Set(0..<keepCount)
        var slotForId: [String: Int] = [:]

        for (slot, sat) in kept.enumerated() where sat.isLocked {
            slotForId[sat.id] = slot
            unassignedSlots.remove(slot)
        }
        for backhaulType in [BackhaulType.wired, BackhaulType.wireless] {
            let unlocked = kept.filter { !$0.isLocked && $0.backhaul == backhaulType }
            var remainingSlots = Set(unassignedSlots.filter { kept[$0].backhaul == backhaulType })
            for sat in unlocked {
                if let bestSlot = remainingSlots.min(by: {
                    simd_distance(sat.position, proposal.satellitePositions[$0]) < simd_distance(sat.position, proposal.satellitePositions[$1])
                }) {
                    slotForId[sat.id] = bestSlot
                    remainingSlots.remove(bestSlot)
                    unassignedSlots.remove(bestSlot)
                }
            }
        }
        for sat in kept where slotForId[sat.id] == nil {
            if let fallbackSlot = unassignedSlots.min() {
                slotForId[sat.id] = fallbackSlot
                unassignedSlots.remove(fallbackSlot)
            }
        }
        for sat in kept {
            if let slot = slotForId[sat.id], let index = result.firstIndex(where: { $0.id == sat.id }) {
                result[index].position = proposal.satellitePositions[slot]
            }
        }
        if proposal.satellitePositions.count > keepCount {
            let currentSatCount = result.filter(\.isSatellite).count
            for (offset, position) in proposal.satellitePositions.dropFirst(keepCount).enumerated() {
                result.append(RFAccessPoint(name: "Satellite \(currentSatCount + offset + 1)", position: position, isSatellite: true, floor: currentFloor))
            }
        }
        let surplus = Set(existing.dropFirst(keepCount).map(\.id))
        result.removeAll { surplus.contains($0.id) }
        return result
    }

    /// Smallest coverage gain (percentage points) that `compare` reports as an improvement for the same node count.
    nonisolated static let minimumCoverageGain: Float = 1.0
    /// A smaller coverage gain still counts when the median signal rises by at least this much.
    nonisolated static let minimumMedianGainDb: Float = 3.0

    /// Before/after coverage with the full model (direct + reflections), so the numbers match the map.
    nonisolated static func compare(project: FloorplanProject, proposal: PlacementProposal, floor: Int) -> OptimizerComparison {
        let band = project.profile.supportedBands.contains(project.selectedBand) ? project.selectedBand : project.profile.planningBand
        let scale = SignalScale(profile: project.profile)
        let model = PropagationModel(walls: project.walls, band: band, calibration: project.calibration, floorHeight: project.profile.floorHeight)
        let rooms = project.rooms(onFloor: floor)
        // Same grid as the map's final render (`recompute(.full)`), so "Before" equals the map summary exactly.
        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.1, maxCells: 30_000)
        let mask = InteriorMask(grid: grid, polygons: rooms.map(\.polygon))

        let beforeAPs = project.accessPoints
        let existing = project.accessPoints
            .filter { $0.isSatellite && $0.floor == floor && $0.isActive }
            .sorted { ($0.isLocked ? 0 : 1, $0.backhaul == .wired ? 0 : 1) < ($1.isLocked ? 0 : 1, $1.backhaul == .wired ? 0 : 1) }
        let before = SignalFieldGenerator.compute(model: model, accessPoints: beforeAPs, floor: floor, mask: mask, scale: scale)
        let beforeSummary = before?.coverage ?? .empty
        let roomsBefore = before?.roomCoverage(rooms: rooms, accessPoints: beforeAPs) ?? []

        let currentRouterPos = (project.accessPoints.first { !$0.isSatellite && $0.isActive } ?? project.router)?.position ?? proposal.routerPosition
        let currentSatPositions = existing.map(\.position)
        let afterAPs = applyingProposal(proposal, to: project.accessPoints, floor: floor)
        let afterSatellites = afterAPs.filter { $0.isSatellite && $0.floor == floor && $0.isActive }
        let positionsUnchanged = simd_distance(proposal.routerPosition, currentRouterPos) < 1e-3
            && afterSatellites.count == existing.count
            && existing.allSatisfy { oldSat in
                guard let newSat = afterSatellites.first(where: { $0.id == oldSat.id }) else { return false }
                return simd_distance(oldSat.position, newSat.position) < 1e-3
            }

        func alreadyOptimalComparison() -> OptimizerComparison {
            let fallbackProposal = PlacementProposal(
                routerPosition: currentRouterPos,
                satellitePositions: currentSatPositions,
                recommendedSatelliteCount: currentSatPositions.count,
                estimatedCoverageBySatelliteCount: proposal.estimatedCoverageBySatelliteCount,
                executionTimeMs: proposal.executionTimeMs
            )
            return OptimizerComparison(
                projectID: project.id,
                floor: floor,
                proposal: fallbackProposal,
                band: band,
                before: beforeSummary,
                after: beforeSummary,
                roomsBefore: roomsBefore,
                roomsAfter: roomsBefore,
                satellitesToAdd: 0,
                satellitesToRemove: 0,
                isAlreadyOptimal: true
            )
        }

        if positionsUnchanged {
            return alreadyOptimalComparison()
        }

        let after = SignalFieldGenerator.compute(model: model, accessPoints: afterAPs, floor: floor, mask: mask, scale: scale)
        let afterSummary = after?.coverage ?? .empty
        let roomsAfter = after?.roomCoverage(rooms: rooms, accessPoints: afterAPs) ?? []

        // Moving the same nodes for less than a point of coverage (and no clearly stronger signal) is not worth
        // proposing: it is within the model's grid noise and would make Optimize suggest a new spot every run.
        let noImprovement = afterSummary.coveredPercent < beforeSummary.coveredPercent + minimumCoverageGain
            && proposal.satellitePositions.count == existing.count
            && afterSummary.medianRSSI < beforeSummary.medianRSSI + minimumMedianGainDb

        if afterSummary.coveredPercent < beforeSummary.coveredPercent || noImprovement {
            return alreadyOptimalComparison()
        }

        return OptimizerComparison(
            projectID: project.id,
            floor: floor,
            proposal: proposal,
            band: band,
            before: beforeSummary,
            after: afterSummary,
            roomsBefore: roomsBefore,
            roomsAfter: roomsAfter,
            satellitesToAdd: max(0, proposal.satellitePositions.count - existing.count),
            satellitesToRemove: max(0, existing.count - proposal.satellitePositions.count),
            isAlreadyOptimal: false
        )
    }

    // MARK: - Calibration

    public func addMeasurement(rssi: Float) {
        guard let project else { return }
        let measurement = SignalMeasurement(position: project.probe, floor: project.probeFloor, band: project.selectedBand, rssi: rssi)
        mutate(undoable: false, recompute: .none) { $0.measurements.append(measurement) }
    }

    public func removeMeasurement(id: String) {
        mutate(undoable: false, recompute: .none) { $0.measurements.removeAll { $0.id == id } }
    }

    @discardableResult
    public func runCalibration() async -> Calibrator.Result? {
        guard let project else { return nil }
        let token = CancellationToken()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Calibrator.fit(measurements: project.measurements, walls: project.walls, accessPoints: project.accessPoints, profile: project.profile, current: project.calibration, token: token)
            }.value
        } onCancel: { token.cancel() }
        guard !Task.isCancelled, self.project == project, let result else { return nil }
        mutate(recompute: .full, invalidatesModel: true) { $0.calibration = result.calibration }
        return result
    }

    public func resetCalibration() {
        mutate(recompute: .full, invalidatesModel: true) { $0.calibration = .uncalibrated }
    }

    // MARK: - Undo

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        project = previous
        invalidateOptimizer()
        canUndo = !undoStack.isEmpty
        cachedModel = nil
        toast = nil
        refreshInstant()
        recompute(quality: .full)
        scheduleSave()
    }

    private func pushUndo(_ snapshot: FloorplanProject) {
        undoStack.append(snapshot)
        if undoStack.count > 30 { undoStack.removeFirst() }
        canUndo = true
    }

    // MARK: - Diagnostics

    public func diagnosticsText() -> String {
        var text = "Mesh Planner — diagnostics\n\n"
        if let project, let data = try? ProjectStore.encoder().encode(project), let json = String(data: data, encoding: .utf8) {
            text += "[Project]\n\(json)\n\n"
        }
        text += "[Log]\n\(SignalDebugLogger.shared.recentLogs())"
        return text
    }

    // MARK: - Internals

    enum Quality: Sendable {
        case none
        case live
        case full
    }

    private func mutate(undoable: Bool = true, recompute quality: Quality = .full, invalidatesModel: Bool = false, _ change: (inout FloorplanProject) -> Void) {
        guard var copy = project else { return }
        if undoable { pushUndo(copy) }
        change(&copy)
        invalidateOptimizer()
        project = copy
        if invalidatesModel { cachedModel = nil }
        refreshInstant()
        if quality != .none { recompute(quality: quality) }
        scheduleSave()
    }

    private func model(for project: FloorplanProject, band: RFBand) -> PropagationModel {
        let key = "\(project.id)|\(band.rawValue)"
        if let cachedModel, cachedModel.key == key { return cachedModel.model }
        let model = PropagationModel(walls: project.walls, band: band, calibration: project.calibration, floorHeight: project.profile.floorHeight)
        cachedModel = (key, model)
        return model
    }

    private static func needsBackhaulRefresh(from old: FloorplanProject?, to new: FloorplanProject) -> Bool {
        guard let old else { return true }
        guard old.walls == new.walls, old.calibration == new.calibration,
              old.profile.standard == new.profile.standard,
              old.profile.channelWidth24 == new.profile.channelWidth24,
              old.profile.channelWidth5 == new.profile.channelWidth5,
              old.profile.channelWidth6 == new.profile.channelWidth6,
              old.profile.dedicatedBackhaulRadio == new.profile.dedicatedBackhaulRadio,
              old.profile.backhaulBand == new.profile.backhaulBand,
              old.profile.floorHeight == new.profile.floorHeight,
              old.accessPoints.count == new.accessPoints.count else { return true }
        for (a, b) in zip(old.accessPoints, new.accessPoints) {
            if a.id != b.id || a.position != b.position || a.txPower != b.txPower
                || a.isSatellite != b.isSatellite || a.isActive != b.isActive
                || a.floor != b.floor || a.backhaul != b.backhaul {
                return true
            }
        }
        return false
    }

    /// Probe feedback is immediate; backhaul is refreshed only when network inputs change.
    private func refreshInstant() {
        guard let project else { return }
        let model = model(for: project, band: project.selectedBand)
        if Self.needsBackhaulRefresh(from: backhaulKey, to: project) {
            backhaulKey = project
            backhaulTask?.cancel()
            backhaulGeneration += 1
            let generation = backhaulGeneration
            backhaul = [:]
            isComputingBackhaul = true
            let token = CancellationToken()
            backhaulTask = Task { [weak self] in
                let links = await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) {
                        BackhaulPlanner.plan(accessPoints: project.accessPoints, walls: project.walls, profile: project.profile, calibration: project.calibration, token: token)
                    }.value
                } onCancel: { token.cancel() }
                guard let self, generation == self.backhaulGeneration, !Task.isCancelled, self.project?.id == project.id else { return }
                self.backhaul = links
                self.isComputingBackhaul = false
                if let current = self.project {
                    self.probe = Self.reading(project: current, model: self.model(for: current, band: current.selectedBand), backhaul: links, point: current.probe, floor: current.probeFloor)
                }
            }
        }
        probe = FloorplanViewModel.reading(project: project, model: model, backhaul: backhaul, point: project.probe, floor: project.probeFloor)
    }

    nonisolated public static func reading(project: FloorplanProject, model: PropagationModel, backhaul: [String: BackhaulLink], point: SIMD2<Float>, floor: Int) -> ProbeReading {
        let scale = SignalScale(profile: project.profile)
        let aps = project.accessPoints
        let best = model.best(from: aps, to: point, floor: floor)
        let ap = best.index.map { aps[$0] }
        let budget = ap.map { model.linkBudget(from: $0, to: point, floor: floor) }
        let link = LinkRateModel.estimate(rssi: best.rssi, band: model.band, profile: project.profile)
        let link2 = ap.flatMap { backhaul[$0.id] }
        let upstream: Float = ap.map { $0.isSatellite ? (link2?.throughputMbps ?? 0) : .greatestFiniteMagnitude } ?? 0
        let effective = min(link.throughputMbps, upstream)
        let plan = Float(project.profile.internetPlanMbps)
        return ProbeReading(
            point: point,
            floor: floor,
            rssi: best.rssi,
            grade: scale.grade(for: best.rssi),
            link: link,
            budget: budget,
            servingAccessPoint: ap,
            backhaul: link2,
            effectiveThroughputMbps: effective,
            internetMbps: plan > 0 ? min(plan, effective) : nil,
            roomName: project.room(containing: point, floor: floor)?.name
        )
    }

    private struct ComputeOutput: Sendable {
        let field: SignalField
        let image: ImageBox
        let coverageContours: [SIMD4<Float>]
        let weakContours: [SIMD4<Float>]
        let rooms: [RoomCoverage]
    }

    private func recompute(quality: Quality) {
        guard let project, quality != .none else { return }
        if quality == .live {
            if liveInFlight {
                livePending = true
                return
            }
            computeTask?.cancel()
            liveInFlight = true
        } else {
            computeTask?.cancel()
            liveInFlight = false
            livePending = false
        }
        computeGeneration += 1
        let generation = computeGeneration
        let model = model(for: project, band: project.selectedBand)
        let currentFloor = floor
        let scale = self.scale
        let rooms = project.rooms(onFloor: currentFloor)
        let aps = project.accessPoints
        let width = project.width
        let depth = project.depth
        let isLive = quality == .live
        isComputingField = true

        let token = CancellationToken()
        let task = Task { [weak self] in
            let output = await withTaskCancellationHandler {
                await Task.detached(priority: isLive ? .userInitiated : .utility) { () -> ComputeOutput? in
                    let grid = isLive
                        ? FieldGrid.covering(width: width, depth: depth, targetCell: 0.25, maxCells: 5_000)
                        : FieldGrid.covering(width: width, depth: depth, targetCell: 0.1, maxCells: 30_000)
                    let mask = InteriorMask(grid: grid, polygons: rooms.map(\.polygon))
                    guard let field = SignalFieldGenerator.compute(model: model, accessPoints: aps, floor: currentFloor, mask: mask, scale: scale, token: token) else { return nil }
                    return ComputeOutput(
                        field: field,
                        image: ImageBox(image: HeatmapImage.make(from: field)),
                        coverageContours: ContourExtractor.segments(in: field, level: scale.coverageThreshold),
                        weakContours: [],
                        rooms: field.roomCoverage(rooms: rooms, accessPoints: aps)
                    )
                }.value
            } onCancel: {
                token.cancel()
            }
            guard let self, generation == self.computeGeneration else { return }
            if isLive { self.liveInFlight = false }
            // Only the latest request may update the map; late results from older requests are dropped.
            if let output {
                self.field = output.field
                self.heatmapImage = output.image.image
                self.coverageContours = output.coverageContours
                self.weakContours = output.weakContours
                self.coverage = output.field.coverage
                let latestRooms = self.project?.rooms ?? []
                self.roomCoverage = output.rooms.map { cov in
                    guard let room = latestRooms.first(where: { $0.id == cov.id }) else { return cov }
                    return RoomCoverage(id: cov.id, name: room.name, kind: room.kind, labelPoint: cov.labelPoint, summary: cov.summary, grade: cov.grade, servingAccessPointId: cov.servingAccessPointId)
                }
                #if DEBUG
                self.heatmapPublishCount += 1
                if isLive { self.liveHeatmapPublishCount += 1 }
                #endif
            }
            self.isComputingField = false
            if isLive && self.livePending {
                self.livePending = false
                self.recompute(quality: .live)
            }
        }
        computeTask = task
    }

    private func scheduleSave() {
        guard let project, !project.isDemo else { return }
        dirty = true
        saveTask?.cancel()
        let snapshot = project
        let store = self.store
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            do {
                try await store.save(snapshot)
                if self.project == snapshot { self.dirty = false }
            } catch {
                self.errorMessage = "Couldn't save your changes. Free storage and use Retry saving. \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func flushSave() async -> Bool {
        saveTask?.cancel()
        await saveTask?.value
        while dirty, let snapshot = project, !snapshot.isDemo {
            do {
                try await store.save(snapshot)
                if project == snapshot { dirty = false }
            } catch {
                errorMessage = "Couldn't save your changes. Free storage and try again. \(error.localizedDescription)"
                return false
            }
        }
        return true
    }

    /// Resolves a position for a node: inside the home on its floor, off walls, outside furniture.
    private func validPosition(_ target: SIMD2<Float>, floor: Int, previous: SIMD2<Float>?) -> SIMD2<Float>? {
        guard let project else { return nil }
        var p = SIMD2<Float>(max(0.1, min(project.width - 0.1, target.x)), max(0.1, min(project.depth - 0.1, target.y)))
        let rooms = project.rooms(onFloor: floor)
        if !rooms.isEmpty && !rooms.contains(where: { $0.contains(p) }) {
            p = RoomPlanConverter.clampInside(p, rooms: rooms, walls: [])
        }
        let floorWalls = project.walls.filter { $0.floor == floor }
        let obstacles = Geometry.obstacleFootprints(floorWalls, floor: floor)
        if obstacles.contains(where: { Geometry.contains($0, p) }) {
            guard previous == nil, let fallbackRoom = rooms.first(where: { r in !obstacles.contains { Geometry.contains($0, r.labelPoint) } }) else { return previous }
            p = fallbackRoom.labelPoint
        }
        return RoomPlanConverter.pushAwayFromWalls(p, walls: floorWalls)
    }

    private func suggestedSatellitePosition() -> SIMD2<Float> {
        if let weakest = roomCoverage.min(by: { $0.summary.medianRSSI < $1.summary.medianRSSI }) {
            return weakest.labelPoint
        }
        guard let project else { return .zero }
        return SIMD2<Float>(project.width * 0.75, project.depth * 0.75)
    }
}
