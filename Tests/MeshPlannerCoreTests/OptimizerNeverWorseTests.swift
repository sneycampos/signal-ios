import Foundation
import Testing
import simd
@testable import MeshPlannerCore

@Suite("Optimizer never worse")
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
