import Testing
import simd
@testable import SignalCore

@Suite("RoomPlan conversion")
struct RoomPlanConverterTests {
    /// A 5 × 4 m room with a door on the south wall, a window on the north wall and an opening on the east wall.
    func sampleCapture(rotatedBy angle: Float = 0) -> RoomPlanCapture {
        func r(_ x: Float, _ z: Float) -> SIMD2<Float> { Geometry.rotate(SIMD2(x, z), by: angle) }
        let walls = [
            RoomPlanRawSurface(id: "south", p1: r(0, 0), p2: r(5, 0)),
            RoomPlanRawSurface(id: "east", p1: r(5, 0), p2: r(5, 4)),
            RoomPlanRawSurface(id: "north", p1: r(5, 4), p2: r(0, 4)),
            RoomPlanRawSurface(id: "west", p1: r(0, 4), p2: r(0, 0))
        ]
        let openings = [
            RoomPlanRawSurface(id: "door", p1: r(2, 0), p2: r(2.9, 0), category: "door", parentId: "south", isOpen: true),
            RoomPlanRawSurface(id: "window", p1: r(1, 4), p2: r(3, 4), category: "window"),
            RoomPlanRawSurface(id: "gap", p1: r(5, 1), p2: r(5, 2.2), category: "opening")
        ]
        let floor = RoomPlanRawFloor(polygon: [r(0, 0), r(5, 0), r(5, 4), r(0, 4)])
        return RoomPlanCapture(
            surfaces: walls + openings,
            objects: [RoomPlanRawObject(id: "fridge", position: r(4.4, 3.4), dimensions: SIMD2(0.8, 0.7), category: "refrigerator", yaw: angle)],
            floors: [floor],
            sections: [RoomPlanRawSection(label: "kitchen", center: r(2.5, 2))],
            routerMarker: r(1, 1)
        )
    }

    @Test func doorsAreCutOutOfTheirWall() throws {
        let result = RoomPlanConverter.convert(sampleCapture())
        let door = try #require(result.walls.first { $0.kind == .door })
        #expect(door.material.isTransparent)
        let model = PropagationModel(walls: result.walls, band: .five)
        let doorMid = door.midpoint
        let throughDoor = model.wallLoss(doorMid.x, doorMid.y - 1, doorMid.x, doorMid.y + 1, floor: 0)
        let throughWall = model.wallLoss(doorMid.x - 1.2, doorMid.y - 1, doorMid.x - 1.2, doorMid.y + 1, floor: 0)
        #expect(throughDoor < 0.5)
        #expect(throughWall > 5)
    }

    @Test func openingsBecomeGapsNotWalls() throws {
        let result = RoomPlanConverter.convert(sampleCapture())
        let gap = try #require(result.walls.first { $0.kind == .opening })
        #expect(gap.material.isTransparent)
        let wallPieces = result.walls.filter { $0.kind == .wall && abs($0.p1.x - gap.p1.x) < 0.01 && abs($0.p2.x - gap.p2.x) < 0.01 }
        for piece in wallPieces {
            let overlap = min(max(piece.p1.y, piece.p2.y), max(gap.p1.y, gap.p2.y)) - max(min(piece.p1.y, piece.p2.y), min(gap.p1.y, gap.p2.y))
            #expect(overlap < 0.02)
        }
    }

    @Test func windowsUseClearGlassByDefault() throws {
        let result = RoomPlanConverter.convert(sampleCapture())
        let window = try #require(result.walls.first { $0.kind == .window })
        #expect(window.material == .glass)
    }

    @Test func rotatedScansAreAlignedToTheAxes() {
        let result = RoomPlanConverter.convert(sampleCapture(rotatedBy: 0.52))
        for wall in result.walls where wall.kind == .wall {
            let d = wall.p2 - wall.p1
            #expect(min(abs(d.x), abs(d.y)) < 0.01)
        }
        #expect(abs(result.width - 5.6) < 0.1)
        #expect(abs(result.depth - 4.6) < 0.1)
    }

    @Test func objectsBecomeObstacles() {
        let result = RoomPlanConverter.convert(sampleCapture(rotatedBy: 0.3))
        let fridge = result.walls.filter { $0.kind == .obstacle }
        #expect(fridge.count == 4)
        #expect(Set(fridge.map(\.groupId)).count == 1)
        #expect(fridge.allSatisfy { $0.material == .metal })
        #expect(result.furniture.count == 1)
    }

    @Test func roomsComeFromFloorsAndSections() throws {
        let result = RoomPlanConverter.convert(sampleCapture())
        let room = try #require(result.rooms.first)
        #expect(room.kind == .kitchen)
        #expect(abs(room.area - 20) < 0.2)
    }

    @Test func routerMarkerIsKeptInsideTheHome() throws {
        let result = RoomPlanConverter.convert(sampleCapture(rotatedBy: 0.4))
        let router = try #require(result.routerPosition)
        #expect(result.rooms.contains { $0.contains(router) })
    }

    @Test func worldAlignmentRoundTrips() {
        let capture = sampleCapture(rotatedBy: 0.7)
        let result = RoomPlanConverter.convert(capture)
        let world = SIMD2<Float>(1.3, -2.1)
        let plan = result.alignment.planPoint(worldX: world.x, worldZ: world.y)
        #expect(simd_distance(result.alignment.worldPoint(fromPlan: plan), world) < 0.001)
    }

    @Test func partitionTouchingThePerimeterStaysInterior() throws {
        var capture = sampleCapture()
        capture.surfaces.append(RoomPlanRawSurface(id: "partition", p1: SIMD2(2.5, 0), p2: SIMD2(2.5, 4)))
        capture.floors = [
            RoomPlanRawFloor(polygon: [SIMD2(0, 0), SIMD2(2.5, 0), SIMD2(2.5, 4), SIMD2(0, 4)]),
            RoomPlanRawFloor(polygon: [SIMD2(2.5, 0), SIMD2(5, 0), SIMD2(5, 4), SIMD2(2.5, 4)])
        ]
        let result = RoomPlanConverter.convert(capture)
        let partition = try #require(result.walls.first { $0.id == "partition" })
        #expect(!partition.isExterior)
        #expect(partition.material == RFMaterial.masonryInterior)
        let south = try #require(result.walls.first { $0.id == "south" })
        #expect(south.isExterior)
    }

    @Test func cornersAreWelded() {
        let capture = RoomPlanCapture(surfaces: [
            RoomPlanRawSurface(id: "a", p1: SIMD2(0, 0), p2: SIMD2(4, 0)),
            RoomPlanRawSurface(id: "b", p1: SIMD2(4.08, 0.05), p2: SIMD2(4.08, 3))
        ])
        let result = RoomPlanConverter.convert(capture)
        let a = result.walls.first { $0.id == "a" }!
        let b = result.walls.first { $0.id == "b" }!
        #expect(simd_distance(a.p2, b.p1) < 0.001)
    }
}
