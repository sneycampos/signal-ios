import Foundation
import RoomPlan
import simd
import MeshPlannerCore

/// Converts RoomPlan results into the platform-independent capture consumed by `RoomPlanConverter`.
enum RoomPlanExtraction {
    static func capture(
        walls: [CapturedRoom.Surface],
        doors: [CapturedRoom.Surface],
        windows: [CapturedRoom.Surface],
        openings: [CapturedRoom.Surface],
        objects: [CapturedRoom.Object],
        floors: [CapturedRoom.Surface],
        sections: [CapturedRoom.Section],
        routerMarker: simd_float3?,
        routerStory: Int
    ) -> RoomPlanCapture {
        var surfaces: [RoomPlanRawSurface] = []
        surfaces += walls.map { surface($0, category: "wall") }
        surfaces += doors.map { surface($0, category: "door") }
        surfaces += windows.map { surface($0, category: "window") }
        surfaces += openings.map { surface($0, category: "opening") }

        let rawObjects = objects.map { object -> RoomPlanRawObject in
            let t = object.transform
            return RoomPlanRawObject(
                id: object.identifier.uuidString,
                position: SIMD2(t.columns.3.x, t.columns.3.z),
                dimensions: SIMD2(object.dimensions.x, object.dimensions.z),
                category: "\(object.category)",
                yaw: atan2(t.columns.0.z, t.columns.0.x),
                story: object.story
            )
        }

        let rawFloors = floors.map { floor -> RoomPlanRawFloor in
            let t = floor.transform
            var corners = floor.polygonCorners
            if corners.count < 3 {
                let hx = floor.dimensions.x / 2
                let hy = floor.dimensions.y / 2
                corners = [simd_float3(-hx, -hy, 0), simd_float3(hx, -hy, 0), simd_float3(hx, hy, 0), simd_float3(-hx, hy, 0)]
            }
            let polygon = corners.map { corner -> SIMD2<Float> in
                let world = t * simd_float4(corner, 1)
                return SIMD2(world.x, world.z)
            }
            return RoomPlanRawFloor(polygon: polygon, story: floor.story, y: t.columns.3.y)
        }

        let rawSections = sections.map {
            RoomPlanRawSection(label: $0.label.rawValue, center: SIMD2($0.center.x, $0.center.z), story: $0.story)
        }

        let floorY = rawFloors.map(\.y).min() ?? walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min()

        return RoomPlanCapture(
            surfaces: surfaces,
            objects: rawObjects,
            floors: rawFloors,
            sections: rawSections,
            routerMarker: routerMarker.map { SIMD2($0.x, $0.z) },
            routerMarkerStory: routerStory,
            floorY: floorY
        )
    }

    static func capture(from room: CapturedRoom, routerMarker: simd_float3?) -> RoomPlanCapture {
        capture(walls: room.walls, doors: room.doors, windows: room.windows, openings: room.openings, objects: room.objects,
                floors: room.floors, sections: room.sections, routerMarker: routerMarker, routerStory: room.story)
    }

    static func capture(from structure: CapturedStructure, routerMarker: simd_float3?, routerStory: Int) -> RoomPlanCapture {
        capture(walls: structure.walls, doors: structure.doors, windows: structure.windows, openings: structure.openings, objects: structure.objects,
                floors: structure.floors, sections: structure.sections, routerMarker: routerMarker, routerStory: routerStory)
    }

    private static func surface(_ s: CapturedRoom.Surface, category: String) -> RoomPlanRawSurface {
        let t = s.transform
        let center = SIMD2<Float>(t.columns.3.x, t.columns.3.z)
        var direction = SIMD2<Float>(t.columns.0.x, t.columns.0.z)
        let length = simd_length(direction)
        direction = length > 1e-4 ? direction / length : SIMD2(1, 0)
        let half = s.dimensions.x / 2
        var isOpen: Bool?
        if case .door(let open) = s.category { isOpen = open }
        return RoomPlanRawSurface(
            id: s.identifier.uuidString,
            p1: center - direction * half,
            p2: center + direction * half,
            height: s.dimensions.y,
            thickness: max(0.08, s.dimensions.z),
            category: category,
            parentId: s.parentIdentifier?.uuidString,
            isOpen: isOpen,
            story: s.story
        )
    }
}
