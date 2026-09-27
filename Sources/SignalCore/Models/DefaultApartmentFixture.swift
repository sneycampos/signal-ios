import Foundation
import simd

/// 14 m × 10 m demo apartment used by the demo project and the test suite.
public enum DefaultApartmentFixture {
    public static let width: Float = 14.0
    public static let depth: Float = 10.0
    public static let wallHeight: Float = 2.7

    public static var defaultWalls: [RFWallSegment] {
        makeDefaultWalls(closeDoors: false, fillWater: true)
    }

    public static var defaultAccessPoints: [RFAccessPoint] {
        [RFAccessPoint(id: "router_main", name: "Router", position: SIMD2<Float>(8.0, 4.8), txPower: 20.0)]
    }

    public static var rooms: [RoomInfo] {
        func rect(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float) -> [SIMD2<Float>] {
            [SIMD2(x0, z0), SIMD2(x1, z0), SIMD2(x1, z1), SIMD2(x0, z1)]
        }
        return RoomNaming.assignNames([
            RoomInfo(id: "room_living", name: "", kind: .livingRoom, polygon: rect(0, 0, 7, 6)),
            RoomInfo(id: "room_kitchen", name: "", kind: .kitchen, polygon: rect(7, 0, 11, 4)),
            RoomInfo(id: "room_bath", name: "", kind: .bathroom, polygon: rect(11, 0, 14, 4)),
            RoomInfo(id: "room_hall", name: "", kind: .hallway, polygon: [SIMD2(7, 4), SIMD2(14, 4), SIMD2(14, 5.5), SIMD2(9, 5.5), SIMD2(9, 6), SIMD2(7, 6)]),
            RoomInfo(id: "room_bed1", name: "", kind: .bedroom, polygon: rect(0, 6, 5, 10)),
            RoomInfo(id: "room_office", name: "", kind: .office, polygon: rect(5, 6, 9, 10)),
            RoomInfo(id: "room_bed2", name: "", kind: .bedroom, polygon: rect(9, 5.5, 14, 10))
        ])
    }

    public static func makeProject() -> FloorplanProject {
        FloorplanProject(
            id: "demo",
            name: "Demo apartment",
            isDemo: true,
            width: width,
            depth: depth,
            walls: defaultWalls,
            accessPoints: defaultAccessPoints,
            rooms: rooms,
            probe: SIMD2<Float>(2.5, 8.0)
        )
    }

    public static func makeDefaultWalls(closeDoors: Bool = false, fillWater: Bool = true) -> [RFWallSegment] {
        var walls: [RFWallSegment] = []

        func add(_ name: String, _ x1: Float, _ z1: Float, _ x2: Float, _ z2: Float, _ material: RFMaterial, _ group: Int32 = 0, kind: WallKind? = nil, exterior: Bool = false) {
            walls.append(RFWallSegment(
                id: "wall_\(walls.count + 1)",
                name: name,
                p1: SIMD2<Float>(x1, z1),
                p2: SIMD2<Float>(x2, z2),
                material: material,
                thickness: material.defaultThickness,
                height: wallHeight,
                objId: group,
                kind: kind,
                isExterior: exterior
            ))
        }

        let door = closeDoors ? RFMaterial.woodenDoor : RFMaterial.openDoor
        let water = fillWater ? RFMaterial.water : RFMaterial.emptyContainer

        // Exterior brick walls; the south wall has two windows.
        add("South wall 1", 0.0, 0.0, 1.5, 0.0, .brick, exterior: true)
        add("Living room window", 1.5, 0.0, 3.5, 0.0, .glass, kind: .window, exterior: true)
        add("South wall 2", 3.5, 0.0, 8.0, 0.0, .brick, exterior: true)
        add("Kitchen window", 8.0, 0.0, 10.0, 0.0, .glass, kind: .window, exterior: true)
        add("South wall 3", 10.0, 0.0, 14.0, 0.0, .brick, exterior: true)
        add("North wall", 0.0, 10.0, 14.0, 10.0, .brick, exterior: true)
        add("West wall", 0.0, 0.0, 0.0, 10.0, .brick, exterior: true)
        add("East wall", 14.0, 0.0, 14.0, 10.0, .brick, exterior: true)

        // Load-bearing concrete wall at z = 6 with two doorways.
        add("West concrete", 0.0, 6.0, 3.5, 6.0, .concrete)
        add("Bedroom 1 door", 3.5, 6.0, 4.4, 6.0, door, kind: .door)
        add("Center concrete", 4.4, 6.0, 6.8, 6.0, .concrete)
        add("Office door", 6.8, 6.0, 7.7, 6.0, door, kind: .door)
        add("East concrete", 7.7, 6.0, 9.0, 6.0, .concrete)

        // Interior partitions.
        add("Living/kitchen partition", 7.0, 0.0, 7.0, 4.0, .drywall)
        add("Bedroom/office partition", 5.0, 6.0, 5.0, 10.0, .drywall)
        add("South hallway 1", 7.0, 4.0, 7.5, 4.0, .drywall)
        add("Kitchen door", 7.5, 4.0, 8.4, 4.0, door, kind: .door)
        add("South hallway 2", 8.4, 4.0, 11.0, 4.0, .drywall)
        add("North hallway 1", 9.0, 5.5, 11.2, 5.5, .drywall)
        add("Bedroom 2 door", 11.2, 5.5, 12.1, 5.5, door, kind: .door)
        add("North hallway 2", 12.1, 5.5, 14.0, 5.5, .drywall)
        add("Office/bedroom 2 partition", 9.0, 6.0, 9.0, 10.0, .drywall)

        // Bathroom (tiled).
        add("Kitchen/bathroom partition", 11.0, 0.0, 11.0, 4.0, .tiledDrywall)
        add("Bathroom 1", 11.0, 4.0, 11.5, 4.0, .tiledDrywall)
        add("Bathroom door", 11.5, 4.0, 12.4, 4.0, door, kind: .door)
        add("Bathroom 2", 12.4, 4.0, 14.0, 4.0, .tiledDrywall)

        // Obstacles: each box shares a group id and is counted once per ray.
        let fridge = "Refrigerator"
        add(fridge, 10.2, 0.1, 11.0, 0.1, .metal, 1)
        add(fridge, 11.0, 0.1, 11.0, 0.8, .metal, 1)
        add(fridge, 11.0, 0.8, 10.2, 0.8, .metal, 1)
        add(fridge, 10.2, 0.8, 10.2, 0.1, .metal, 1)

        let aquarium = "Aquarium"
        add(aquarium, 0.4, 3.0, 1.6, 3.0, water, 2)
        add(aquarium, 1.6, 3.0, 1.6, 3.4, water, 2)
        add(aquarium, 1.6, 3.4, 0.4, 3.4, water, 2)
        add(aquarium, 0.4, 3.4, 0.4, 3.0, water, 2)

        let bathtub = "Bathtub"
        add(bathtub, 13.25, 0.2, 13.25, 1.9, water, 3)
        add(bathtub, 13.25, 1.9, 14.0, 1.9, water, 3)
        add(bathtub, 14.0, 1.9, 14.0, 0.2, water, 3)
        add(bathtub, 14.0, 0.2, 13.25, 0.2, water, 3)

        let shelf = "Metal shelf"
        add(shelf, 5.35, 7.0, 5.35, 8.8, .metal, 4)
        add(shelf, 5.35, 8.8, 5.0, 8.8, .metal, 4)
        add(shelf, 5.0, 8.8, 5.0, 7.0, .metal, 4)
        add(shelf, 5.0, 7.0, 5.35, 7.0, .metal, 4)

        return walls
    }
}
