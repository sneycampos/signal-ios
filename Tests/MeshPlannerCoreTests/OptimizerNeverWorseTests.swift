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

    @Test func routerOnlyMatchesBruteForceReferenceWithinTolerance() throws {
        var demo = DefaultApartmentFixture.makeProject()
        let rooms = demo.rooms(onFloor: 0)
        let obstacles = Geometry.obstacleFootprints(demo.walls, floor: 0)
        let floorWalls = demo.walls.filter { $0.floor == 0 && $0.isActive && !$0.material.isTransparent }
        let model = PropagationModel(walls: demo.walls, band: demo.profile.planningBand, calibration: demo.calibration, floorHeight: demo.profile.floorHeight)
        let scale = SignalScale(profile: demo.profile)
        let evalGrid = FieldGrid.covering(width: demo.width, depth: demo.depth, targetCell: 0.2, maxCells: 12_000)
        let mask = InteriorMask(grid: evalGrid, polygons: rooms.map(\.polygon))

        // Brute-force 0.75 m grid + doorway/room-center reference over the floorplan using the full SignalFieldGenerator (0.2 m, reflections: true).
        let refGrid = FieldGrid.covering(width: demo.width, depth: demo.depth, targetCell: 0.75, maxCells: 600)
        var refPoints: [SIMD2<Float>] = [SIMD2(6.0, 5.0), SIMD2(5.8, 5.0), SIMD2(6.2, 5.0)] + rooms.map(\.labelPoint)
        for row in 0..<refGrid.rows {
            for col in 0..<refGrid.cols {
                refPoints.append(refGrid.center(col: col, row: row))
            }
        }
        var bruteForceBestCoverage: Float = 0
        for p in refPoints {
            guard rooms.contains(where: { $0.contains(p) }),
                  PlacementOptimizer.isPlaceable(p, walls: floorWalls, obstacles: obstacles) else { continue }
            let ap = RFAccessPoint(name: "Router", position: p, txPower: demo.accessPoints[0].txPower, floor: 0)
            if let field = SignalFieldGenerator.compute(model: model, accessPoints: [ap], floor: 0, mask: mask, scale: scale, reflections: true) {
                if field.coverage.coveredPercent > bruteForceBestCoverage {
                    bruteForceBestCoverage = field.coverage.coveredPercent
                }
            }
        }
        #expect(bruteForceBestCoverage >= 86.0)

        // Start from a weak corner (~38% coverage) and run router-only optimization.
        demo.accessPoints[0].position = SIMD2<Float>(13.3, 9.3)
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
            comp.after.coveredPercent >= bruteForceBestCoverage - 1.5,
            "Optimizer after (\(comp.after.coveredPercent)%) should be within 1.5% of brute-force reference (\(bruteForceBestCoverage)%)"
        )
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
