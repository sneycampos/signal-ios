import Testing
import simd
@testable import MeshPlannerCore

@Suite("Placement optimizer and calibration")
struct OptimizerAndCalibrationTests {
    let project = DefaultApartmentFixture.makeProject()

    func request(_ satellites: SatelliteCountOption, lock: Bool = false, aps: [RFAccessPoint]? = nil) -> PlacementRequest {
        PlacementRequest(walls: project.walls, rooms: project.rooms, accessPoints: aps ?? project.accessPoints, profile: project.profile, width: project.width, depth: project.depth, satellites: satellites, lockRouter: lock)
    }

    @Test func proposedPositionsAreInsideAndOffFurniture() throws {
        let proposal = try #require(PlacementOptimizer.optimize(request(.exactly(2))))
        let obstacles = Geometry.obstacleFootprints(project.walls, floor: 0)
        for p in [proposal.routerPosition] + proposal.satellitePositions {
            #expect(project.rooms.contains { $0.contains(p) })
            #expect(!obstacles.contains { Geometry.contains($0, p) })
            #expect(project.walls.filter { !$0.material.isTransparent }.allSatisfy { $0.distance(to: p) >= PlacementOptimizer.wallClearance - 1e-3 })
        }
    }

    @Test func satellitesRespectBackhaul() throws {
        let proposal = try #require(PlacementOptimizer.optimize(request(.exactly(2))))
        let model = PropagationModel(walls: project.walls, band: .five)
        let nodes = [proposal.routerPosition] + proposal.satellitePositions
        for (i, sat) in proposal.satellitePositions.enumerated() {
            let anchors = nodes.prefix(i + 1) + nodes.dropFirst(i + 2)
            let best = anchors.map { model.rssi(from: RFAccessPoint(name: "", position: $0), to: sat, floor: 0, reflections: false) }.max() ?? -200
            #expect(best >= PlacementOptimizer.minimumBackhaulRSSI - 0.5)
        }
    }

    @Test func moreNodesNeverReduceEstimatedCoverage() throws {
        let proposal = try #require(PlacementOptimizer.optimize(request(.automatic)))
        let values = proposal.estimatedCoverageBySatelliteCount
        #expect(values.count >= 2)
        for i in 1..<values.count { #expect(values[i] >= values[i - 1] - 1) }
        #expect(proposal.recommendedSatelliteCount >= 0)
    }

    @Test func lockedRouterStaysPut() throws {
        var router = project.accessPoints[0]
        router.position = SIMD2(1, 1)
        let proposal = try #require(PlacementOptimizer.optimize(request(.exactly(1), lock: true, aps: [router])))
        #expect(proposal.routerPosition == SIMD2(1, 1))
    }

    @Test func optimizerCanBeCancelled() {
        let token = CancellationToken()
        token.cancel()
        #expect(PlacementOptimizer.optimize(request(.automatic), token: token) == nil)
    }

    @Test func calibrationRecoversTheTrueModel() throws {
        let truth = Calibration(pathLossExponent: 2.6, wallLossScale: 1.3, offsetDb: -2)
        let model = PropagationModel(walls: project.walls, band: .five, calibration: truth)
        let points: [SIMD2<Float>] = [SIMD2(2, 2), SIMD2(5, 3), SIMD2(9, 2), SIMD2(12, 2), SIMD2(2.5, 8), SIMD2(7, 8), SIMD2(12, 8), SIMD2(10, 4.8)]
        let measurements = points.map { SignalMeasurement(position: $0, band: .five, rssi: model.best(from: project.accessPoints, to: $0, floor: 0).rssi) }
        let result = try #require(Calibrator.fit(measurements: measurements, walls: project.walls, accessPoints: project.accessPoints, profile: project.profile))
        #expect(result.rmsAfter < result.rmsBefore)
        #expect(result.rmsAfter < 1.0)
        #expect(abs(result.calibration.pathLossExponent - 2.6) < 0.25)
    }
}
