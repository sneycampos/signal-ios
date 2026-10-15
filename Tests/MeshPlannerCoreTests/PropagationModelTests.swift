import Testing
import simd
@testable import MeshPlannerCore

@Suite("Propagation model")
struct PropagationModelTests {
    let walls = DefaultApartmentFixture.defaultWalls
    let cornerRouter = RFAccessPoint(id: "router", name: "Router", position: SIMD2<Float>(0.5, 0.5))

    func model(_ band: RFBand = .five, walls: [RFWallSegment]? = nil) -> PropagationModel {
        PropagationModel(walls: walls ?? self.walls, band: band)
    }

    @Test func cornerRouterLeavesBedroomWeak() {
        let rssi = model().rssi(from: cornerRouter, to: SIMD2(2.5, 8.0), floor: 0, reflections: false)
        #expect(rssi < -67)
    }

    @Test func bandsAreOrderedByReach() {
        let point = SIMD2<Float>(2.5, 8.0)
        let r24 = model(.twoPointFour).rssi(from: cornerRouter, to: point, floor: 0, reflections: false)
        let r5 = model(.five).rssi(from: cornerRouter, to: point, floor: 0, reflections: false)
        let r6 = model(.six).rssi(from: cornerRouter, to: point, floor: 0, reflections: false)
        #expect(r24 > r5)
        #expect(r5 > r6)
    }

    @Test func refrigeratorCastsMetalShadow() {
        let ap = RFAccessPoint(name: "AP", position: SIMD2(10.6, 2.5))
        let behind = model().rssi(from: ap, to: SIMD2(10.6, 0.15), floor: 0, reflections: false)
        let beside = model().rssi(from: ap, to: SIMD2(9.5, 0.15), floor: 0, reflections: false)
        #expect(beside - behind >= 25)
    }

    @Test func drainingAquariumRemovesShadow() {
        let ap = RFAccessPoint(name: "AP", position: SIMD2(1.0, 1.5))
        let point = SIMD2<Float>(1.0, 4.5)
        let full = model(walls: DefaultApartmentFixture.makeDefaultWalls(fillWater: true)).rssi(from: ap, to: point, floor: 0, reflections: false)
        let empty = model(walls: DefaultApartmentFixture.makeDefaultWalls(fillWater: false)).rssi(from: ap, to: point, floor: 0, reflections: false)
        #expect(empty - full > 12)
    }

    @Test func reflectionsNeverWeakenTheDirectPath() {
        for point in [SIMD2<Float>(4.0, 6.8), SIMD2(2.5, 8), SIMD2(12, 2), SIMD2(8, 9)] {
            let direct = model().rssi(from: cornerRouter, to: point, floor: 0, reflections: false)
            let total = model().rssi(from: cornerRouter, to: point, floor: 0, reflections: true)
            #expect(total >= direct)
        }
    }

    @Test func separateObstaclesAreEachCounted() {
        func box(_ x0: Float, _ group: Int32) -> [RFWallSegment] {
            let c = [SIMD2<Float>(x0, -1), SIMD2(x0 + 0.5, -1), SIMD2(x0 + 0.5, 1), SIMD2(x0, 1)]
            return (0..<4).map { RFWallSegment(p1: c[$0], p2: c[($0 + 1) % 4], material: .metal, objId: group) }
        }
        let boxes = box(2, 1001) + box(5, 1002)
        let loss = model(walls: boxes).wallLoss(0, 0.01, 8, 0.01, floor: 0)
        #expect(loss > 65)
    }

    @Test func facesOfOneObstacleCountOnce() {
        let c = [SIMD2<Float>(2, -1), SIMD2(2.5, -1), SIMD2(2.5, 1), SIMD2(2, 1)]
        let box = (0..<4).map { RFWallSegment(p1: c[$0], p2: c[($0 + 1) % 4], material: .metal, objId: 7) }
        let loss = model(walls: box).wallLoss(0, 0.01, 8, 0.01, floor: 0)
        #expect(abs(loss - 35) < 0.5)
    }

    @Test func wallJointsDoNotLeak() {
        let split = [
            RFWallSegment(p1: SIMD2(5, -5), p2: SIMD2(5, 0), material: .concrete),
            RFWallSegment(p1: SIMD2(5, 0), p2: SIMD2(5, 5), material: .concrete)
        ]
        let loss = model(walls: split).wallLoss(0, 0, 10, 0, floor: 0)
        #expect(abs(loss - 28) < 0.5, "one crossing, not zero and not double")
    }

    @Test func smallScanGapsAreClosed() {
        let gapped = [
            RFWallSegment(p1: SIMD2(5, -5), p2: SIMD2(5, -0.01), material: .concrete),
            RFWallSegment(p1: SIMD2(5, 0.005), p2: SIMD2(5, 5), material: .concrete)
        ]
        #expect(model(walls: gapped).wallLoss(0, 0, 10, 0, floor: 0) > 27)
    }

    @Test func obstacleAgainstWallAddsBothLosses() {
        let wall = RFWallSegment(p1: SIMD2(5, -3), p2: SIMD2(5, 3), material: .drywall)
        let c = [SIMD2<Float>(5, -1), SIMD2(5.35, -1), SIMD2(5.35, 1), SIMD2(5, 1)]
        let shelf = (0..<4).map { RFWallSegment(p1: c[$0], p2: c[($0 + 1) % 4], material: .metal, objId: 4) }
        let loss = model(walls: [wall] + shelf).wallLoss(0, 0.2, 10, 0.2, floor: 0)
        #expect(abs(loss - 39) < 1)
    }

    @Test func linkBudgetMatchesFastPath() {
        let m = model()
        for point in [SIMD2<Float>(2.5, 8), SIMD2(12, 2), SIMD2(6, 3), SIMD2(13, 9)] {
            let budget = m.linkBudget(from: cornerRouter, to: point, floor: 0)
            let fast = m.rssi(from: cornerRouter, to: point, floor: 0)
            #expect(abs(budget.finalRssiDbm - fast) < 0.001)
            #expect(abs(budget.txPowerDbm - budget.deviceMarginDb - budget.freeSpaceLossDb - budget.wallLossDb - budget.directRssiDbm) < 0.001)
        }
    }

    @Test func bestServerIsTheStrongestNotTheSum() {
        let a = RFAccessPoint(name: "A", position: SIMD2(1, 1))
        let b = RFAccessPoint(name: "B", position: SIMD2(1, 1.01))
        let m = model(walls: [])
        let single = m.rssi(from: a, to: SIMD2(5, 5), floor: 0)
        let both = m.best(from: [a, b], to: SIMD2(5, 5), floor: 0).rssi
        #expect(abs(both - single) < 0.1)
    }

    @Test func slabLossAppliesBetweenFloors() {
        let upstairs = RFAccessPoint(name: "A", position: SIMD2(2, 2), floor: 1)
        let floorWalls = [RFWallSegment(p1: SIMD2(0, 10), p2: SIMD2(1, 10), material: .drywall, floor: 1)]
        let m = PropagationModel(walls: floorWalls, band: .five)
        let sameFloor = m.rssi(from: upstairs, to: SIMD2(2, 4), floor: 1)
        let below = m.rssi(from: upstairs, to: SIMD2(2, 4), floor: 0)
        #expect(sameFloor - below > 28)
    }

    @Test func calibrationScalesTheModel() {
        let base = model().rssi(from: cornerRouter, to: SIMD2(6, 3), floor: 0, reflections: false)
        let steeper = PropagationModel(walls: walls, band: .five, calibration: Calibration(pathLossExponent: 3)).rssi(from: cornerRouter, to: SIMD2(6, 3), floor: 0, reflections: false)
        #expect(steeper < base)
    }
}
