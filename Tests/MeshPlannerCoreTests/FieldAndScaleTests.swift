import Testing
import simd
@testable import MeshPlannerCore

@Suite("Signal field, scale and link rate")
struct FieldAndScaleTests {
    @Test func coverageOnlyCountsTheInterior() throws {
        // L-shaped home inside a 10 × 10 bounding box: the empty quadrant must not count.
        let lShape: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(5, 5), SIMD2(5, 10), SIMD2(0, 10)]
        let grid = FieldGrid.covering(width: 10, depth: 10, targetCell: 0.25, maxCells: 10_000)
        let mask = InteriorMask(grid: grid, polygons: [lShape])
        let interior = (0..<grid.count).filter { mask.isInterior($0) }.count
        #expect(abs(Float(interior) / Float(grid.count) - 0.75) < 0.02)

        let model = PropagationModel(walls: [], band: .five)
        let ap = RFAccessPoint(name: "AP", position: SIMD2(2, 2))
        let field = try #require(SignalFieldGenerator.compute(model: model, accessPoints: [ap], floor: 0, mask: mask, scale: .default))
        #expect(field.coverage.cellCount == interior)
        #expect(!mask.contains(SIMD2(8, 8)))
    }

    @Test func demoCoverageMatchesProbeModel() throws {
        let project = DefaultApartmentFixture.makeProject()
        let model = PropagationModel(walls: project.walls, band: .five)
        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.25, maxCells: 5_000)
        let mask = InteriorMask(grid: grid, polygons: project.rooms.map(\.polygon))
        let field = try #require(SignalFieldGenerator.compute(model: model, accessPoints: project.accessPoints, floor: 0, mask: mask, scale: .default))
        let point = grid.center(col: 10, row: 30)
        let value = try #require(field.value(at: point))
        #expect(abs(value - model.best(from: project.accessPoints, to: point, floor: 0).rssi) < 0.001)
        let rooms = field.roomCoverage(rooms: project.rooms, accessPoints: project.accessPoints)
        #expect(rooms.count == project.rooms.count)
    }

    @Test func contoursFollowTheThreshold() throws {
        let grid = FieldGrid.covering(width: 10, depth: 10, targetCell: 0.25, maxCells: 10_000)
        let mask = InteriorMask(grid: grid, polygons: [])
        let model = PropagationModel(walls: [], band: .five)
        let field = try #require(SignalFieldGenerator.compute(model: model, accessPoints: [RFAccessPoint(name: "AP", position: SIMD2(5, 5), txPower: -5)], floor: 0, mask: mask, scale: .default))
        let segments = ContourExtractor.segments(in: field, level: -67)
        #expect(!segments.isEmpty)
        for s in segments.prefix(20) {
            let mid = SIMD2<Float>((s.x + s.z) / 2, (s.y + s.w) / 2)
            #expect(abs(model.rssi(from: RFAccessPoint(name: "AP", position: SIMD2(5, 5), txPower: -5), to: mid, floor: 0) + 67) < 1.5)
        }
    }

    @Test func gradesAndColorsShareThresholds() {
        let scale = SignalScale.default
        #expect(scale.grade(for: -66.9) == .good)
        #expect(scale.grade(for: -67.1) == .fair)
        #expect(scale.grade(for: -54) == .excellent)
        #expect(scale.grade(for: -90) == .none)
        let below = scale.color(for: -67.05)
        let above = scale.color(for: -66.95)
        #expect(abs(below.r - above.r) > 0.2, "visible step at the coverage threshold")
        #expect(scale.grade(for: scale.representativeRSSI(for: .fair)) == .fair)
    }

    @Test func noiseFloorDependsOnChannelWidth() {
        #expect(abs(LinkRateModel.noiseFloor(channelWidthMHz: 20) - -94) < 0.2)
        #expect(abs(LinkRateModel.noiseFloor(channelWidthMHz: 80) - -88) < 0.2)
    }

    @Test func linkRateIsMonotonicAndCapped() {
        let profile = NetworkProfile()
        var previous: Float = -1
        for rssi in stride(from: Float(-95), through: -30, by: 1) {
            let rate = LinkRateModel.estimate(rssi: rssi, band: .five, profile: profile).phyRateMbps
            #expect(rate >= previous)
            previous = rate
        }
        let wifi5 = NetworkProfile(standard: .wifi5)
        let strong = LinkRateModel.estimate(rssi: -30, band: .five, profile: wifi5)
        #expect(strong.mcs == 9)
        #expect(strong.throughputMbps < strong.phyRateMbps)
        #expect(LinkRateModel.estimate(rssi: -95, band: .five, profile: profile).mcs == nil)
    }

    @Test func backhaulLimitsSatelliteThroughput() throws {
        let walls = DefaultApartmentFixture.defaultWalls
        let router = RFAccessPoint(id: "r", name: "R", position: SIMD2(8, 4.8))
        let far = RFAccessPoint(id: "s", name: "S", position: SIMD2(1, 9), isSatellite: true)
        let plan = BackhaulPlanner.plan(accessPoints: [router, far], walls: walls, profile: NetworkProfile())
        let link = try #require(plan["s"])
        #expect(link.parentId == "r")
        let wired = BackhaulPlanner.plan(accessPoints: [router, RFAccessPoint(id: "s", name: "S", position: SIMD2(1, 9), isSatellite: true, backhaul: .wired)], walls: walls, profile: NetworkProfile())
        #expect(wired["s"]?.quality == .wired)
        #expect((wired["s"]?.throughputMbps ?? 0) > link.throughputMbps)
    }

    @Test func satellitesChainThroughTheBestParent() throws {
        let router = RFAccessPoint(id: "r", name: "R", position: SIMD2(1, 1))
        let middle = RFAccessPoint(id: "m", name: "M", position: SIMD2(8, 1), isSatellite: true)
        let far = RFAccessPoint(id: "f", name: "F", position: SIMD2(15, 1), isSatellite: true)
        let walls = [RFWallSegment(p1: SIMD2(4.5, -2), p2: SIMD2(4.5, 4), material: .brick), RFWallSegment(p1: SIMD2(11.5, -2), p2: SIMD2(11.5, 4), material: .brick)]
        let plan = BackhaulPlanner.plan(accessPoints: [router, middle, far], walls: walls, profile: NetworkProfile())
        #expect(plan["f"]?.parentId == "m")
        #expect(plan["f"]?.hops == 2)
    }
}
