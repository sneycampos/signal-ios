import Foundation
import Testing
import simd
@testable import MeshPlannerCore

@Suite("Optimizer never worse", .serialized)
struct OptimizerNeverWorseTests {
    @Test func optimizerProposalIsNeverWorseThanCurrentPlacement() throws {
        // 1. Demo apartment fixture with router manually moved to a strong central spot.
        var demo = DefaultApartmentFixture.makeProject()
        demo.accessPoints[0].position = SIMD2<Float>(6.0, 5.0)
        demo.accessPoints[0].isLocked = false

        let demoRequest = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let demoProposal = try #require(PlacementOptimizer.optimize(demoRequest))
        let demoComparison = FloorplanViewModel.compare(project: demo, proposal: demoProposal, floor: 0)
        #expect(
            demoComparison.after.coveredPercent >= demoComparison.before.coveredPercent,
            "Demo fixture: proposed coverage (\(demoComparison.after.coveredPercent)%) must never be worse than current coverage (\(demoComparison.before.coveredPercent)%)"
        )

        // 2. Repaired scan fixture with router manually moved to the same strong spot.
        var scanned = ProjectRepair.upgradeIfNeeded(RealScanTests.legacyFixture())
        scanned.accessPoints[0].position = SIMD2<Float>(6.0, 5.0)
        scanned.accessPoints[0].isLocked = false

        let scannedRequest = PlacementRequest(
            walls: scanned.walls,
            rooms: scanned.rooms,
            accessPoints: scanned.accessPoints,
            profile: scanned.profile,
            calibration: scanned.calibration,
            width: scanned.width,
            depth: scanned.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let scannedProposal = try #require(PlacementOptimizer.optimize(scannedRequest))
        let scannedComparison = FloorplanViewModel.compare(project: scanned, proposal: scannedProposal, floor: 0)
        #expect(
            scannedComparison.after.coveredPercent >= scannedComparison.before.coveredPercent,
            "Scanned fixture: proposed coverage (\(scannedComparison.after.coveredPercent)%) must never be worse than current coverage (\(scannedComparison.before.coveredPercent)%)"
        )
    }

    @Test func routerOnlyOptionsAndPoorRouterImprovement() throws {
        var demo = DefaultApartmentFixture.makeProject()
        // Place router in a far corner of bedroom 2 where coverage across the home is weak.
        demo.accessPoints[0].position = SIMD2<Float>(13.3, 9.3)
        demo.accessPoints[0].isLocked = false

        // 1. SatelliteCountOption.exactly(0) moves a poorly placed router to a strictly better spot.
        let exactZeroReq = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let exactZeroProposal = try #require(PlacementOptimizer.optimize(exactZeroReq))
        #expect(exactZeroProposal.satellitePositions.isEmpty)
        #expect(exactZeroProposal.recommendedSatelliteCount == 0)
        let exactZeroComp = FloorplanViewModel.compare(project: demo, proposal: exactZeroProposal, floor: 0)
        #expect(exactZeroComp.after.coveredPercent > exactZeroComp.before.coveredPercent)
        #expect(!exactZeroComp.isAlreadyOptimal)
        #expect(exactZeroComp.satellitesToAdd == 0)
        #expect(exactZeroComp.satellitesToRemove == 0)

        // 2. SatelliteCountOption.automatic with maxSatellites == 0 also acts as router-only.
        let autoZeroReq = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .automatic,
            lockRouter: false,
            maxSatellites: 0
        )
        let autoZeroProposal = try #require(PlacementOptimizer.optimize(autoZeroReq))
        #expect(autoZeroProposal.satellitePositions.isEmpty)
        #expect(autoZeroProposal.recommendedSatelliteCount == 0)
        let autoZeroComp = FloorplanViewModel.compare(project: demo, proposal: autoZeroProposal, floor: 0)
        #expect(autoZeroComp.after.coveredPercent > autoZeroComp.before.coveredPercent)
        #expect(!autoZeroComp.isAlreadyOptimal)

        // 3. Automatic with default maxSatellites on a small room recommends 0 satellites when router alone covers >= 90%.
        let smallRoom = RoomInfo(name: "Studio", kind: .livingRoom, polygon: [[0, 0], [5, 0], [5, 5], [0, 5]])
        let studioReq = PlacementRequest(
            walls: [],
            rooms: [smallRoom],
            accessPoints: [RFAccessPoint(name: "Router", position: [0.6, 0.6])],
            profile: NetworkProfile(),
            width: 5,
            depth: 5,
            floor: 0,
            satellites: .automatic,
            lockRouter: false
        )
        let studioProposal = try #require(PlacementOptimizer.optimize(studioReq))
        #expect(studioProposal.recommendedSatelliteCount == 0)
        #expect(studioProposal.satellitePositions.isEmpty)
    }

    @Test @MainActor func wellPlacedRouterWithZeroSatellitesIsAlreadyOptimalAndNotApplied() async throws {
        var scanned = ProjectRepair.upgradeIfNeeded(RealScanTests.legacyFixture())
        let initialRequest = PlacementRequest(
            walls: scanned.walls,
            rooms: scanned.rooms,
            accessPoints: scanned.accessPoints,
            profile: scanned.profile,
            calibration: scanned.calibration,
            width: scanned.width,
            depth: scanned.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let optimalRouterProposal = try #require(PlacementOptimizer.optimize(initialRequest))
        scanned.accessPoints[0].position = optimalRouterProposal.routerPosition
        scanned.accessPoints[0].isLocked = false

        let request = PlacementRequest(
            walls: scanned.walls,
            rooms: scanned.rooms,
            accessPoints: scanned.accessPoints,
            profile: scanned.profile,
            calibration: scanned.calibration,
            width: scanned.width,
            depth: scanned.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let proposal = try #require(PlacementOptimizer.optimize(request))
        let comparison = FloorplanViewModel.compare(project: scanned, proposal: proposal, floor: 0)
        #expect(comparison.isAlreadyOptimal)
        #expect(comparison.after.coveredPercent >= comparison.before.coveredPercent)
        #expect(comparison.proposal.routerPosition == scanned.accessPoints[0].position)

        // Verify that a worse proposal is clamped by compare() to isAlreadyOptimal.
        let artificiallyWorseProposal = PlacementProposal(
            routerPosition: SIMD2<Float>(13.3, 9.3),
            satellitePositions: [],
            recommendedSatelliteCount: 0,
            estimatedCoverageBySatelliteCount: [50],
            executionTimeMs: 1
        )
        let guardedComparison = FloorplanViewModel.compare(project: scanned, proposal: artificiallyWorseProposal, floor: 0)
        #expect(guardedComparison.isAlreadyOptimal)
        #expect(guardedComparison.after == guardedComparison.before)
        #expect(guardedComparison.proposal.routerPosition == scanned.accessPoints[0].position)
        #expect(guardedComparison.satellitesToAdd == 0)
        #expect(guardedComparison.satellitesToRemove == 0)

        // Exercise FloorplanViewModel.applyOptimizerResult() on scanned when already optimal.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDirectory: root)
        try await store.save(scanned)

        let model = FloorplanViewModel(store: store)
        await model.open(id: scanned.id)
        model.runOptimizer(satellites: .exactly(0), lockRouter: false)
        let deadline = ContinuousClock.now + .seconds(5)
        while case .running = model.optimizer, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready(let vmComparison) = model.optimizer else {
            Issue.record("Expected optimizer ready state")
            await model.close()
            return
        }
        #expect(vmComparison.isAlreadyOptimal)
        model.applyOptimizerResult()
        #expect(model.optimizer == .idle)
        #expect(!model.canUndo)
        #expect(model.toast == nil)
        #expect(model.project?.accessPoints == scanned.accessPoints)
        await model.close()
    }

    @Test func inactiveSatellitesAreIgnoredDuringOptimization() throws {
        var demo = DefaultApartmentFixture.makeProject()
        let inactiveSat = RFAccessPoint(
            name: "Inactive Sat",
            position: SIMD2<Float>(12.0, 8.0),
            txPower: 30,
            isSatellite: true,
            isActive: false,
            floor: 0,
            backhaul: .wired
        )
        demo.accessPoints.append(inactiveSat)

        let req = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let proposal = try #require(PlacementOptimizer.optimize(req))
        let comparison = FloorplanViewModel.compare(project: demo, proposal: proposal, floor: 0)
        #expect(comparison.satellitesToRemove == 0)
        #expect(comparison.after.coveredPercent >= comparison.before.coveredPercent)
    }

    @Test(arguments: [
        (false, 0), (false, 1), (false, 2), (false, 3), (false, 4), (false, 5),
        (true, 0), (true, 1), (true, 2), (true, 3), (true, 4), (true, 5)
    ])
    func propertyRandomPlacementsNeverWorseAcrossDemoAndScanFixtures(useScannedFixture: Bool, trial: Int) throws {
        var rng = SplitMix64(seed: useScannedFixture ? 0x2026_1015_0008 : 0x2026_1015_0007)
        let baseProject = useScannedFixture
            ? ProjectRepair.upgradeIfNeeded(RealScanTests.legacyFixture())
            : DefaultApartmentFixture.makeProject()

        let floorRooms = baseProject.rooms(onFloor: 0)
        let floorWalls = baseProject.walls.filter { $0.floor == 0 }
        let obstacles = Geometry.obstacleFootprints(floorWalls, floor: 0)

        var validSpots: [SIMD2<Float>] = []
        var attempts = 0
        while validSpots.count < 30 && attempts < 1000 {
            attempts += 1
            let x = Float.random(in: 0.4...(baseProject.width - 0.4), using: &rng)
            let y = Float.random(in: 0.4...(baseProject.depth - 0.4), using: &rng)
            let p = RoomPlanConverter.pushAwayFromWalls(SIMD2<Float>(x, y), walls: floorWalls)
            if floorRooms.contains(where: { $0.contains(p) }) && !obstacles.contains(where: { Geometry.contains($0, p) }) {
                validSpots.append(p)
            }
        }
        #expect(validSpots.count >= 20)

        var project = baseProject
        let routerPos = validSpots[trial % validSpots.count]
        project.accessPoints = [RFAccessPoint(name: "Router", position: routerPos, floor: 0, isLocked: false)]

        let existingSatCount = trial % 3 // 0, 1, or 2 existing satellites
        for s in 0..<existingSatCount {
            let satPos = validSpots[(trial * 7 + s * 5 + 3) % validSpots.count]
            project.accessPoints.append(
                RFAccessPoint(name: "Sat \(s + 1)", position: satPos, isSatellite: true, floor: 0, backhaul: (s == 0 && trial % 2 == 1) ? .wired : .wireless)
            )
        }

        let targetSatCount = min(2, existingSatCount + (trial / 3) % 2)
        let option: SatelliteCountOption = (trial == 5) ? .automatic : .exactly(targetSatCount)
        let lockRouter = (trial == 4)

        let request = PlacementRequest(
            walls: project.walls,
            rooms: project.rooms,
            accessPoints: project.accessPoints,
            profile: project.profile,
            calibration: project.calibration,
            width: project.width,
            depth: project.depth,
            floor: 0,
            satellites: option,
            lockRouter: lockRouter,
            maxSatellites: 2
        )
        let proposal = try #require(PlacementOptimizer.optimize(request))
        let comparison = FloorplanViewModel.compare(project: project, proposal: proposal, floor: 0)
        #expect(
            comparison.after.coveredPercent >= comparison.before.coveredPercent,
            "Trial \(trial) on \(project.name) (sats=\(option), existing=\(existingSatCount), lock=\(lockRouter)): after \(comparison.after.coveredPercent)% < before \(comparison.before.coveredPercent)%"
        )
    }

    @Test func routerOnlyFromWeakSpotFindsKnownStrongCoverageOnDemoAndScannedFixtures() throws {
        // Case A: DefaultApartmentFixture — manual placement at (6.0, 5.0) reaches ~88.3% coverage.
        var demoManual = DefaultApartmentFixture.makeProject()
        demoManual.accessPoints[0].position = SIMD2<Float>(6.0, 5.0)
        let manualDummyProposal = PlacementProposal(
            routerPosition: SIMD2<Float>(6.0, 5.0),
            satellitePositions: [],
            recommendedSatelliteCount: 0,
            estimatedCoverageBySatelliteCount: [88],
            executionTimeMs: 0
        )
        let manualComp = FloorplanViewModel.compare(project: demoManual, proposal: manualDummyProposal, floor: 0)
        #expect(manualComp.before.coveredPercent >= 87.5)

        // Move router to ~72% spots and a weak corner (~38%), then optimize with 0 satellites.
        for weakStart in [SIMD2<Float>(3.0, 2.5), SIMD2<Float>(9.5, 4.8), SIMD2<Float>(13.3, 9.3)] {
            var demo = DefaultApartmentFixture.makeProject()
            demo.accessPoints[0].position = weakStart
            demo.accessPoints[0].isLocked = false

            let req = PlacementRequest(
                walls: demo.walls,
                rooms: demo.rooms,
                accessPoints: demo.accessPoints,
                profile: demo.profile,
                calibration: demo.calibration,
                width: demo.width,
                depth: demo.depth,
                floor: 0,
                satellites: .exactly(0),
                lockRouter: false
            )
            let proposal = try #require(PlacementOptimizer.optimize(req))
            let comp = FloorplanViewModel.compare(project: demo, proposal: proposal, floor: 0)
            #expect(
                comp.after.coveredPercent >= 86.5,
                "Demo router-only from \(weakStart) (\(comp.before.coveredPercent)%) only reached \(comp.after.coveredPercent)%, expected >= 86.5%"
            )
            #expect(comp.after.coveredPercent >= manualComp.before.coveredPercent - 1.5)
        }

        // Case B: Repaired scan fixture — manual placement at (6.0, 5.0) reaches ~90.6% coverage.
        for weakStart in [SIMD2<Float>(3.0, 2.5), SIMD2<Float>(13.3, 9.3)] {
            var scanned = ProjectRepair.upgradeIfNeeded(RealScanTests.legacyFixture())
            scanned.accessPoints[0].position = weakStart
            scanned.accessPoints[0].isLocked = false

            let req = PlacementRequest(
                walls: scanned.walls,
                rooms: scanned.rooms,
                accessPoints: scanned.accessPoints,
                profile: scanned.profile,
                calibration: scanned.calibration,
                width: scanned.width,
                depth: scanned.depth,
                floor: 0,
                satellites: .exactly(0),
                lockRouter: false
            )
            let proposal = try #require(PlacementOptimizer.optimize(req))
            let comp = FloorplanViewModel.compare(project: scanned, proposal: proposal, floor: 0)
            #expect(
                comp.after.coveredPercent >= 89.0,
                "Scanned router-only from \(weakStart) (\(comp.before.coveredPercent)%) only reached \(comp.after.coveredPercent)%, expected >= 89.0%"
            )
        }
    }

    /// Router-only fixtures with their best achievable map coverage.
    ///
    /// References were computed once by brute force (scratch benchmark, not part of the suite): every position on a
    /// 0.05 m lattice that is inside a room and `PlacementOptimizer.isPlaceable` (0.15 m wall clearance) was scored
    /// with `SignalFieldGenerator` (reflections on) on the 0.2 m `InteriorMask` grid; the best 600 were re-scored on
    /// the map's final grid (`FieldGrid.covering(targetCell: 0.1, maxCells: 30_000)`, the metric `compare()` uses).
    /// Best positions: demo 96.60% @ (6.95, 6.00); brick 87.33% @ (6.95, 6.00); closed doors 87.59% @ (7.45, 5.85);
    /// mirrored cases are the same values at y' = 10 − y. A 0.75 m grid tops out ~1 point lower and misses these.
    enum RouterOnlyFixture: String, CaseIterable, CustomTestStringConvertible {
        case demo, brickPartitions, closedDoors, demoMirroredY, brickPartitionsMirroredY

        var testDescription: String { rawValue }

        var referenceCoverage: Float {
            switch self {
            case .demo, .demoMirroredY: 96.60
            case .brickPartitions, .brickPartitionsMirroredY: 87.33
            case .closedDoors: 87.59
            }
        }

        var isMirrored: Bool { self == .demoMirroredY || self == .brickPartitionsMirroredY }

        func project() -> FloorplanProject {
            var project = DefaultApartmentFixture.makeProject()
            switch self {
            case .demo, .demoMirroredY:
                break
            case .brickPartitions, .brickPartitionsMirroredY:
                project.walls = project.walls.map { wall in
                    var wall = wall
                    if wall.kind == .wall { wall.material = .brick }
                    return wall
                }
            case .closedDoors:
                project.walls = DefaultApartmentFixture.makeDefaultWalls(closeDoors: true)
            }
            guard isMirrored else { return project }
            let depth = project.depth
            project.walls = project.walls.map { wall in
                var wall = wall
                wall.p1.y = depth - wall.p1.y
                wall.p2.y = depth - wall.p2.y
                return wall
            }
            project.rooms = project.rooms.map { room in
                var room = room
                room.polygon = room.polygon.reversed().map { SIMD2($0.x, depth - $0.y) }
                return room
            }
            return project
        }

        /// Weak corners/rooms plus the demo's default router spot (which used to stop in a local optimum).
        var starts: [SIMD2<Float>] {
            let base: [SIMD2<Float>] = [[3.0, 2.5], [9.5, 4.8], [13.3, 9.3], [1.0, 9.0], [12.5, 1.2], [8.0, 4.8]]
            return isMirrored ? base.map { SIMD2($0.x, DefaultApartmentFixture.depth - $0.y) } : base
        }
    }

    private static func routerOnlyRequest(_ project: FloorplanProject) -> PlacementRequest {
        PlacementRequest(
            walls: project.walls,
            rooms: project.rooms,
            accessPoints: project.accessPoints,
            profile: project.profile,
            calibration: project.calibration,
            width: project.width,
            depth: project.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
    }

    private static func project(_ fixture: RouterOnlyFixture, routerAt start: SIMD2<Float>) -> FloorplanProject {
        var project = fixture.project()
        let floorWalls = project.walls.filter { $0.floor == 0 && $0.isActive && !$0.material.isTransparent }
        project.accessPoints[0].position = RoomPlanConverter.pushAwayFromWalls(start, walls: floorWalls, clearance: PlacementOptimizer.wallClearance + 0.01)
        project.accessPoints[0].isLocked = false
        return project
    }

    @Test(arguments: RouterOnlyFixture.allCases)
    func routerOnlyReachesBruteForceReferenceFromEveryStart(fixture: RouterOnlyFixture) throws {
        var results: [Float] = []
        for start in fixture.starts {
            let project = Self.project(fixture, routerAt: start)
            let proposal = try #require(PlacementOptimizer.optimize(Self.routerOnlyRequest(project)))
            let comp = FloorplanViewModel.compare(project: project, proposal: proposal, floor: 0)
            #expect(
                comp.after.coveredPercent >= fixture.referenceCoverage - 1.0,
                "\(fixture) from \(start) (\(comp.before.coveredPercent)%) reached \(comp.after.coveredPercent)% at \(comp.proposal.routerPosition); brute-force optimum is \(fixture.referenceCoverage)%"
            )
            results.append(comp.after.coveredPercent)
        }
        // The answer must not depend on where the router starts.
        let spread = (results.max() ?? 0) - (results.min() ?? 0)
        #expect(spread <= 0.5, "\(fixture): router-only results differ by \(spread) points across starts: \(results)")
    }

    @Test(arguments: RouterOnlyFixture.allCases)
    func routerOnlyOptimizeApplyOptimizeIsIdempotent(fixture: RouterOnlyFixture) throws {
        for start in [fixture.starts[0], fixture.starts[5]] {
            var project = Self.project(fixture, routerAt: start)
            let first = try #require(PlacementOptimizer.optimize(Self.routerOnlyRequest(project)))
            let firstComp = FloorplanViewModel.compare(project: project, proposal: first, floor: 0)
            if !firstComp.isAlreadyOptimal {
                project.accessPoints = FloorplanViewModel.applyingProposal(firstComp.proposal, to: project.accessPoints, floor: 0)
            }

            let second = try #require(PlacementOptimizer.optimize(Self.routerOnlyRequest(project)))
            let secondComp = FloorplanViewModel.compare(project: project, proposal: second, floor: 0)
            #expect(
                secondComp.isAlreadyOptimal,
                "\(fixture) from \(start): after applying \(firstComp.after.coveredPercent)%, Optimize again offered \(secondComp.before.coveredPercent)% → \(secondComp.after.coveredPercent)%"
            )
            #expect(secondComp.after.coveredPercent - secondComp.before.coveredPercent < FloorplanViewModel.minimumCoverageGain)
        }
    }

    @Test func compareReportsTrivialGainsAsAlreadyOptimalAndMatchesTheMap() throws {
        let demo = DefaultApartmentFixture.makeProject()
        let router = demo.accessPoints[0].position

        // "Before" uses the map's final-render grid, so it equals the coverage summary shown on the map.
        let grid = FieldGrid.covering(width: demo.width, depth: demo.depth, targetCell: 0.1, maxCells: 30_000)
        let mask = InteriorMask(grid: grid, polygons: demo.rooms(onFloor: 0).map(\.polygon))
        let model = PropagationModel(walls: demo.walls, band: demo.selectedBand, calibration: demo.calibration, floorHeight: demo.profile.floorHeight)
        let mapField = try #require(SignalFieldGenerator.compute(model: model, accessPoints: demo.accessPoints, floor: 0, mask: mask, scale: SignalScale(profile: demo.profile)))

        // A 5 cm nudge changes coverage by far less than a point: not worth proposing.
        let nudge = PlacementProposal(
            routerPosition: router + SIMD2<Float>(0.05, 0),
            satellitePositions: [],
            recommendedSatelliteCount: 0,
            estimatedCoverageBySatelliteCount: [80],
            executionTimeMs: 0
        )
        let comp = FloorplanViewModel.compare(project: demo, proposal: nudge, floor: 0)
        #expect(comp.before.coveredPercent == mapField.coverage.coveredPercent)
        #expect(comp.isAlreadyOptimal)
        #expect(comp.after == comp.before)
        #expect(comp.proposal.routerPosition == router)
    }

    /// The user-visible flow through the view model: the sheet's "Before" equals the map, "After" equals the map once
    /// applied, and optimizing again right away reports the placement as already the best.
    @Test(arguments: RouterOnlyFixture.allCases)
    @MainActor func viewModelOptimizeApplyOptimizeMatchesTheMapAndSettles(fixture: RouterOnlyFixture) async throws {
        // starts[5] is the demo's default router spot, where Optimize used to stop at 93% and then offer 96%.
        let base = Self.project(fixture, routerAt: fixture.starts[5])
        let project = FloorplanProject(
            id: UUID().uuidString,
            name: base.name,
            width: base.width,
            depth: base.depth,
            walls: base.walls,
            accessPoints: base.accessPoints,
            rooms: base.rooms,
            probe: base.probe
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDirectory: root)
        try await store.save(project)

        let model = FloorplanViewModel(store: store)
        await model.open(id: project.id)
        try await Self.waitUntil { !model.isComputing && (model.field?.grid.cell ?? 1) <= 0.11 }

        let first = try await Self.runRouterOnly(model)
        #expect(!first.isAlreadyOptimal, "\(fixture): a weak start must get a proposal")
        #expect(first.before.coveredPercent == model.coverage.coveredPercent, "\(fixture): sheet Before \(first.before.coveredPercent)% vs map \(model.coverage.coveredPercent)%")
        #expect(first.after.coveredPercent >= fixture.referenceCoverage - 1.0)

        let published = model.heatmapPublishCount
        model.applyOptimizerResult()
        try await Self.waitUntil { model.heatmapPublishCount > published && !model.isComputing && (model.field?.grid.cell ?? 1) <= 0.11 }
        #expect(model.project?.router?.position == first.proposal.routerPosition)
        #expect(model.coverage.coveredPercent == first.after.coveredPercent, "\(fixture): sheet After \(first.after.coveredPercent)% vs map \(model.coverage.coveredPercent)% after applying")

        let second = try await Self.runRouterOnly(model)
        #expect(second.isAlreadyOptimal, "\(fixture): Optimize right after Apply offered \(second.before.coveredPercent)% → \(second.after.coveredPercent)%")
        #expect(second.before.coveredPercent == model.coverage.coveredPercent)
        await model.close()
    }

    @MainActor private static func runRouterOnly(_ model: FloorplanViewModel) async throws -> OptimizerComparison {
        model.runOptimizer(satellites: .exactly(0), lockRouter: false)
        try await waitUntil {
            if case .running = model.optimizer { return false }
            return true
        }
        guard case .ready(let comparison) = model.optimizer else {
            Issue.record("Expected optimizer ready state, got \(model.optimizer)")
            throw CancellationError()
        }
        return comparison
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Background work did not reach the expected state")
    }

    @Test func compareCountsAClearlyStrongerSignalAsAnImprovement() throws {
        // Open 5 m studio: the corner router already covers (almost) everything, so coverage barely changes, but the
        // centre gives a much stronger median signal — that is still worth proposing.
        let studio = FloorplanProject(
            id: "studio",
            name: "Studio",
            width: 5,
            depth: 5,
            walls: [],
            accessPoints: [RFAccessPoint(name: "Router", position: [0.6, 0.6])],
            rooms: [RoomInfo(name: "Studio", kind: .livingRoom, polygon: [[0, 0], [5, 0], [5, 5], [0, 5]])],
            probe: [4, 4]
        )
        let centre = PlacementProposal(routerPosition: [2.5, 2.5], satellitePositions: [], recommendedSatelliteCount: 0, estimatedCoverageBySatelliteCount: [100], executionTimeMs: 0)
        let comp = FloorplanViewModel.compare(project: studio, proposal: centre, floor: 0)
        try #require(comp.before.coveredPercent > 100 - FloorplanViewModel.minimumCoverageGain, "Fixture must exercise the median rule")
        #expect(!comp.isAlreadyOptimal)
        #expect(comp.after.medianRSSI >= comp.before.medianRSSI + FloorplanViewModel.minimumMedianGainDb)
    }

    /// Reference computed once by brute force (scratch benchmark): router locked at (13.3, 9.3) in the demo, one
    /// satellite tried at every placeable 0.2 m grid point whose direct backhaul from the router is ≥ −70 dBm, scored
    /// on the map's 0.1 m grid. Best: 98.14% with the satellite at (3.70, 5.90).
    @Test func oneSatelliteWithLockedWeakRouterMatchesBruteForceReference() throws {
        var demo = DefaultApartmentFixture.makeProject()
        demo.accessPoints[0].position = SIMD2<Float>(13.3, 9.3)
        demo.accessPoints[0].isLocked = true
        let request = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(1),
            lockRouter: true
        )
        let proposal = try #require(PlacementOptimizer.optimize(request))
        #expect(proposal.routerPosition == demo.accessPoints[0].position)
        let comp = FloorplanViewModel.compare(project: demo, proposal: proposal, floor: 0)
        #expect(comp.satellitesToAdd == 1)
        #expect(comp.after.coveredPercent >= 98.14 - 1.0, "1 satellite reached \(comp.after.coveredPercent)% at \(proposal.satellitePositions)")
    }

    /// Calibration shifts every transmitter by `offsetDb`; satellite backhaul checks must include it like coverage does.
    @Test(arguments: [Float(-6), Float(4)])
    func calibratedSatellitesKeepBackhaulAndNeverMakeThingsWorse(offsetDb: Float) throws {
        var demo = DefaultApartmentFixture.makeProject()
        demo.calibration = Calibration(offsetDb: offsetDb)
        demo.accessPoints[0].position = SIMD2<Float>(3.0, 2.5)
        let request = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(2),
            lockRouter: false
        )
        let proposal = try #require(PlacementOptimizer.optimize(request))
        #expect(proposal.satellitePositions.count == 2)
        let backhaul = PropagationModel(walls: demo.walls, band: demo.profile.effectiveBackhaulBand, calibration: demo.calibration, floorHeight: demo.profile.floorHeight)
        let nodes = [proposal.routerPosition] + proposal.satellitePositions
        for (i, sat) in proposal.satellitePositions.enumerated() {
            let others = nodes.enumerated().filter { $0.offset != i + 1 }.map(\.element)
            let best = others.map { backhaul.rssi(from: RFAccessPoint(name: "", position: $0), to: sat, floor: 0, reflections: false) }.max() ?? -200
            #expect(best >= PlacementOptimizer.minimumBackhaulRSSI - 0.5, "offset \(offsetDb) dB: satellite \(i) backhaul \(best) dBm")
        }
        let comp = FloorplanViewModel.compare(project: demo, proposal: proposal, floor: 0)
        #expect(comp.after.coveredPercent >= comp.before.coveredPercent)
    }

    @Test @MainActor func lockedSatelliteStaysPutAndUnlockedSatellitesPreserveIdentity() async throws {
        let base = DefaultApartmentFixture.makeProject()
        var demo = FloorplanProject(
            id: UUID().uuidString,
            name: base.name,
            width: base.width,
            depth: base.depth,
            walls: base.walls,
            accessPoints: base.accessPoints,
            rooms: base.rooms,
            furniture: base.furniture,
            probe: base.probe
        )
        let lockedSat = RFAccessPoint(
            id: "sat-locked",
            name: "Pinned Hall Sat",
            position: SIMD2<Float>(3.5, 5.0),
            isSatellite: true,
            floor: 0,
            backhaul: .wireless,
            isLocked: true
        )
        let unlockedSat = RFAccessPoint(
            id: "sat-unlocked",
            name: "Movable Bedroom Sat",
            position: SIMD2<Float>(12.5, 8.5),
            isSatellite: true,
            floor: 0,
            backhaul: .wireless,
            isLocked: false
        )
        demo.accessPoints.append(contentsOf: [lockedSat, unlockedSat])

        let req = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(2),
            lockRouter: false
        )
        let proposal = try #require(PlacementOptimizer.optimize(req))
        #expect(proposal.satellitePositions.count == 2)
        #expect(simd_distance(proposal.satellitePositions[0], lockedSat.position) < 1e-3)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDirectory: root)
        try await store.save(demo)

        let model = FloorplanViewModel(store: store)
        await model.open(id: demo.id)
        model.runOptimizer(satellites: .exactly(2), lockRouter: false)
        let deadline = ContinuousClock.now + .seconds(5)
        while case .running = model.optimizer, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if case .ready(let comp) = model.optimizer, !comp.isAlreadyOptimal {
            model.applyOptimizerResult()
        }
        let afterLocked = try #require(model.accessPoint(id: "sat-locked"))
        let afterUnlocked = try #require(model.accessPoint(id: "sat-unlocked"))
        #expect(simd_distance(afterLocked.position, lockedSat.position) < 1e-3)
        #expect(afterLocked.name == "Pinned Hall Sat")
        #expect(afterUnlocked.name == "Movable Bedroom Sat")
        await model.close()
    }

    @Test func optimizerPerformanceBudget() throws {
        var demo = DefaultApartmentFixture.makeProject()
        demo.accessPoints[0].position = SIMD2<Float>(3.0, 2.5)

        let req0 = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let prop0 = try #require(PlacementOptimizer.optimize(req0))
        #expect(prop0.executionTimeMs < 600, "Router-only took \(prop0.executionTimeMs) ms")

        let reqAuto = PlacementRequest(
            walls: demo.walls,
            rooms: demo.rooms,
            accessPoints: demo.accessPoints,
            profile: demo.profile,
            calibration: demo.calibration,
            width: demo.width,
            depth: demo.depth,
            floor: 0,
            satellites: .automatic,
            lockRouter: false,
            maxSatellites: 3
        )
        let propAuto = try #require(PlacementOptimizer.optimize(reqAuto))
        #expect(propAuto.executionTimeMs < 1500, "Automatic (0...3 sats) took \(propAuto.executionTimeMs) ms")
    }

    @Test func tallFloorLowerHalfOptimalSpotIsFoundWithoutTruncation() throws {
        // Tall floorplan (10 m × 24 m) wherecandGrid produces > 600 interior points (> maxCandidates = 320).
        // The upper half (y = 0...12) is a low-importance hallway; the lower half (y = 12...24) has three
        // bedrooms separated by concrete walls that only open into a lower-half hub (y ≈ 18).
        // Only a router placed in the lower half (y > 12) can cover the lower bedrooms well.
        let rooms: [RoomInfo] = [
            RoomInfo(id: "upper_hall", name: "Upper Gallery", kind: .hallway, polygon: [[0, 0], [10, 0], [10, 12], [0, 12]]),
            RoomInfo(id: "lower_hub", name: "Lower Living", kind: .livingRoom, polygon: [[3, 12], [7, 12], [7, 24], [3, 24]]),
            RoomInfo(id: "bed_left", name: "Lower West Bedroom", kind: .bedroom, polygon: [[0, 12], [3, 12], [3, 24], [0, 24]]),
            RoomInfo(id: "bed_right", name: "Lower East Bedroom", kind: .bedroom, polygon: [[7, 12], [10, 12], [10, 24], [7, 24]])
        ]
        // Heavy concrete walls partitioning the upper gallery into small bays and enclosing the lower bedrooms
        // with open gaps (not .door/.opening) into the lower hub around y = 18.
        let walls: [RFWallSegment] = [
            RFWallSegment(p1: [0, 3], p2: [10, 3], material: .concrete),
            RFWallSegment(p1: [0, 6], p2: [10, 6], material: .concrete),
            RFWallSegment(p1: [0, 9], p2: [10, 9], material: .concrete),
            RFWallSegment(p1: [0, 12], p2: [10, 12], material: .concrete),
            RFWallSegment(p1: [3, 12], p2: [3, 17], material: .concrete),
            RFWallSegment(p1: [3, 19], p2: [3, 24], material: .concrete),
            RFWallSegment(p1: [7, 12], p2: [7, 17], material: .concrete),
            RFWallSegment(p1: [7, 19], p2: [7, 24], material: .concrete)
        ]
        let router = RFAccessPoint(name: "Router", position: SIMD2<Float>(5.0, 2.0), floor: 0, isLocked: false)
        let req = PlacementRequest(
            walls: walls,
            rooms: rooms,
            accessPoints: [router],
            profile: NetworkProfile(),
            width: 10,
            depth: 24,
            floor: 0,
            satellites: .exactly(0),
            lockRouter: false
        )
        let proposal = try #require(PlacementOptimizer.optimize(req))
        #expect(
            proposal.routerPosition.y > 12.0,
            "Expected router to move into the lower half (y > 12), but got \(proposal.routerPosition)"
        )
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
