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
    public private(set) var isComputing = false
    public var optimizer: OptimizerState = .idle
    public private(set) var canUndo = false
    public var toast: ToastMessage?
    public var errorMessage: String?
    /// Set after a scan so the map asks for the equipment details once.
    public var shouldPresentSetup = false

    // MARK: Private

    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private var computeGeneration = 0
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
        if let migrated = await store.migrateLegacyScanIfNeeded() {
            SignalDebugLogger.shared.log("Migrated legacy scan to project \(migrated.id)", category: "Store")
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
    public var scale: SignalScale { SignalScale(profile: project?.profile ?? NetworkProfile()) }
    public var band: RFBand { project?.selectedBand ?? .five }

    public func open(id: String) async {
        do {
            let loaded = try await store.load(id: id)
            hasWorldMap = await store.worldMap(for: id) != nil
            await present(loaded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func openDemo() async {
        hasWorldMap = false
        await present(DefaultApartmentFixture.makeProject())
    }

    private func present(_ newProject: FloorplanProject) async {
        guard await flushSave() else { return }
        cancelOptimizer()
        project = newProject
        floor = min(newProject.probeFloor, newProject.floorCount - 1)
        selection = nil
        tool = .normal
        undoStack = []
        canUndo = false
        optimizer = .idle
        field = nil
        heatmapImage = nil
        coverage = .empty
        roomCoverage = []
        coverageContours = []
        weakContours = []
        cachedModel = nil
        backhaulKey = nil
        refreshInstant()
        recompute(quality: .full)
    }

    public func close() async {
        guard await flushSave() else { return }
        cancelOptimizer()
        computeTask?.cancel()
        backhaulTask?.cancel()
        computeGeneration += 1
        isComputing = false
        project = nil
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
            computeGeneration += 1
            cancelOptimizer()
            dirty = false
            project = nil
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
            try await store.save(newProject)
            if let worldMap {
                try await store.saveWorldMap(worldMap, for: newProject.id)
            }
            hasWorldMap = worldMap != nil
            await present(newProject)
            if converted.routerPosition == nil {
                tool = .placeRouter
            }
            shouldPresentSetup = true
            await refreshProjects()
            SignalDebugLogger.shared.log("Created project: \(converted.walls.count) segments, \(converted.rooms.count) rooms, \(converted.floorCount) floor(s)", category: "Scan")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Import / export

    public func importProject(from url: URL) async {
        do {
            let imported = try await store.importProject(from: url)
            await refreshProjects()
            hasWorldMap = false
            await present(imported)
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
        mutate(undoable: false, recompute: .full) { $0.selectedBand = band }
    }

    public func setFloor(_ newFloor: Int) {
        guard let project, newFloor >= 0, newFloor < project.floorCount, newFloor != floor else { return }
        floor = newFloor
        invalidateOptimizer()
        selection = nil
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
        var ap = project.accessPoints[index]
        change(&ap)
        guard ap != project.accessPoints[index] else { return }
        mutate(recompute: .full) { $0.accessPoints[index] = ap }
    }

    public func updateRoom(id: String, name: String? = nil, kind: RoomKind? = nil) {
        guard let index = project?.rooms.firstIndex(where: { $0.id == id }) else { return }
        mutate(recompute: .full) { p in
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { p.rooms[index].name = name }
            if let kind { p.rooms[index].kind = kind }
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
        let constructionChanged = profile.construction != project.profile.construction
        mutate(recompute: .full, invalidatesModel: true) { p in
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
            lockRouter: lockRouter
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
            guard let self, !token.isCancelled, self.project == snapshot, self.floor == currentFloor else { return }
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

    public func applyOptimizerResult() {
        guard case .ready(let comparison) = optimizer, project == optimizerSnapshot,
              project?.id == comparison.projectID, floor == comparison.floor else { invalidateOptimizer(); return }
        let proposal = comparison.proposal
        let currentFloor = floor
        mutate(recompute: .full) { p in
            if let routerIndex = p.accessPoints.firstIndex(where: { !$0.isSatellite }) {
                p.accessPoints[routerIndex].position = proposal.routerPosition
            }
            let satelliteIds = p.accessPoints.filter { $0.isSatellite && $0.floor == currentFloor }.map(\.id)
            for (i, position) in proposal.satellitePositions.enumerated() {
                if i < satelliteIds.count, let index = p.accessPoints.firstIndex(where: { $0.id == satelliteIds[i] }) {
                    p.accessPoints[index].position = position
                } else {
                    p.accessPoints.append(RFAccessPoint(name: "Satellite \(p.satellites.count + 1)", position: position, isSatellite: true, floor: currentFloor))
                }
            }
            let surplus = Set(satelliteIds.dropFirst(proposal.satellitePositions.count))
            p.accessPoints.removeAll { surplus.contains($0.id) }
        }
        optimizer = .idle
        toast = ToastMessage(text: "Positions applied.", offersUndo: true)
    }

    /// Before/after coverage with the full model (direct + reflections), so the numbers match the map.
    nonisolated static func compare(project: FloorplanProject, proposal: PlacementProposal, floor: Int) -> OptimizerComparison {
        let band = project.profile.planningBand
        let scale = SignalScale(profile: project.profile)
        let model = PropagationModel(walls: project.walls, band: band, calibration: project.calibration, floorHeight: project.profile.floorHeight)
        let rooms = project.rooms(onFloor: floor)
        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.2, maxCells: 12_000)
        let mask = InteriorMask(grid: grid, polygons: rooms.map(\.polygon))

        let beforeAPs = project.accessPoints
        var afterAPs = project.accessPoints.filter { !($0.isSatellite && $0.floor == floor) }
        if let r = afterAPs.firstIndex(where: { !$0.isSatellite }) { afterAPs[r].position = proposal.routerPosition }
        let existing = project.accessPoints.filter { $0.isSatellite && $0.floor == floor }
        for (i, position) in proposal.satellitePositions.enumerated() {
            var sat = i < existing.count ? existing[i] : RFAccessPoint(name: "", position: position, isSatellite: true, floor: floor)
            sat.position = position
            afterAPs.append(sat)
        }
        let before = SignalFieldGenerator.compute(model: model, accessPoints: beforeAPs, floor: floor, mask: mask, scale: scale)
        let after = SignalFieldGenerator.compute(model: model, accessPoints: afterAPs, floor: floor, mask: mask, scale: scale)
        return OptimizerComparison(
            projectID: project.id,
            floor: floor,
            proposal: proposal,
            band: band,
            before: before?.coverage ?? .empty,
            after: after?.coverage ?? .empty,
            roomsBefore: before?.roomCoverage(rooms: rooms, accessPoints: beforeAPs) ?? [],
            roomsAfter: after?.roomCoverage(rooms: rooms, accessPoints: afterAPs) ?? [],
            satellitesToAdd: max(0, proposal.satellitePositions.count - existing.count),
            satellitesToRemove: max(0, existing.count - proposal.satellitePositions.count)
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

    /// Probe feedback is immediate; backhaul is refreshed only when network inputs change.
    private func refreshInstant() {
        guard let project else { return }
        let model = model(for: project, band: project.selectedBand)
        if backhaulKey?.accessPoints != project.accessPoints || backhaulKey?.walls != project.walls || backhaulKey?.profile != project.profile || backhaulKey?.calibration != project.calibration {
            backhaulKey = project
            backhaulTask?.cancel()
            let token = CancellationToken()
            backhaulTask = Task { [weak self] in
                let links = await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) {
                        BackhaulPlanner.plan(accessPoints: project.accessPoints, walls: project.walls, profile: project.profile, calibration: project.calibration, token: token)
                    }.value
                } onCancel: { token.cancel() }
                guard let self, !Task.isCancelled, self.project?.id == project.id else { return }
                self.backhaul = links
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
        computeTask?.cancel()
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
        if !isLive { computeTask?.cancel() }
        isComputing = true

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
            guard let self else { return }
            // Only the latest request may update the map; late results from older requests are dropped.
            if let output, generation == self.computeGeneration {
                self.field = output.field
                self.heatmapImage = output.image.image
                self.coverageContours = output.coverageContours
                self.weakContours = output.weakContours
                self.coverage = output.field.coverage
                self.roomCoverage = output.rooms
                self.isComputing = false
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
            return previous
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
