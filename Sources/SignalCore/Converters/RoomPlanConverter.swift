import Foundation
import simd

// MARK: - Raw capture (platform-independent mirror of RoomPlan output, world XZ coordinates)

public struct RoomPlanRawSurface: Codable, Sendable {
    public let id: String
    public let p1: SIMD2<Float>
    public let p2: SIMD2<Float>
    public let height: Float
    public let thickness: Float
    /// "wall", "door", "window" or "opening".
    public let category: String
    /// Wall that contains this door/window/opening (RoomPlan `parentIdentifier`).
    public let parentId: String?
    /// For doors: whether RoomPlan saw the door open. nil when unknown.
    public let isOpen: Bool?
    public let story: Int

    public init(
        id: String = UUID().uuidString,
        p1: SIMD2<Float>,
        p2: SIMD2<Float>,
        height: Float = 2.7,
        thickness: Float = 0.12,
        category: String = "wall",
        parentId: String? = nil,
        isOpen: Bool? = nil,
        story: Int = 0
    ) {
        self.id = id
        self.p1 = p1
        self.p2 = p2
        self.height = height
        self.thickness = thickness
        self.category = category
        self.parentId = parentId
        self.isOpen = isOpen
        self.story = story
    }
}

public struct RoomPlanRawObject: Codable, Sendable, Identifiable {
    public let id: String
    public let position: SIMD2<Float>
    /// Footprint: width along the object's local X, depth along its local Z.
    public let dimensions: SIMD2<Float>
    public let category: String
    /// Rotation around the vertical axis (radians, atan2 of the local X axis in world XZ).
    public let yaw: Float
    public let story: Int

    public init(id: String = UUID().uuidString, position: SIMD2<Float>, dimensions: SIMD2<Float>, category: String, yaw: Float = 0, story: Int = 0) {
        self.id = id
        self.position = position
        self.dimensions = dimensions
        self.category = category
        self.yaw = yaw
        self.story = story
    }
}

public struct RoomPlanRawFloor: Codable, Sendable {
    public let polygon: [SIMD2<Float>]
    public let story: Int
    public let y: Float

    public init(polygon: [SIMD2<Float>], story: Int = 0, y: Float = 0) {
        self.polygon = polygon
        self.story = story
        self.y = y
    }
}

public struct RoomPlanRawSection: Codable, Sendable {
    /// RoomPlan section label: "livingRoom", "kitchen", "bedroom", "bathroom", "diningRoom" or "unidentified".
    public let label: String
    public let center: SIMD2<Float>
    public let story: Int

    public init(label: String, center: SIMD2<Float>, story: Int = 0) {
        self.label = label
        self.center = center
        self.story = story
    }
}

public struct RoomPlanCapture: Codable, Sendable {
    public var surfaces: [RoomPlanRawSurface]
    public var objects: [RoomPlanRawObject]
    public var floors: [RoomPlanRawFloor]
    public var sections: [RoomPlanRawSection]
    /// Where the user stood when tapping "I'm next to the router".
    public var routerMarker: SIMD2<Float>?
    public var routerMarkerStory: Int
    /// World height of the floor (for the AR overlay).
    public var floorY: Float?

    public init(
        surfaces: [RoomPlanRawSurface],
        objects: [RoomPlanRawObject] = [],
        floors: [RoomPlanRawFloor] = [],
        sections: [RoomPlanRawSection] = [],
        routerMarker: SIMD2<Float>? = nil,
        routerMarkerStory: Int = 0,
        floorY: Float? = nil
    ) {
        self.surfaces = surfaces
        self.objects = objects
        self.floors = floors
        self.sections = sections
        self.routerMarker = routerMarker
        self.routerMarkerStory = routerMarkerStory
        self.floorY = floorY
    }
}

public struct ConvertedFloorplan: Sendable {
    public let walls: [RFWallSegment]
    public let rooms: [RoomInfo]
    public let furniture: [FurnitureItem]
    public let width: Float
    public let depth: Float
    public let alignment: WorldAlignment
    public let routerPosition: SIMD2<Float>?
    public let routerFloor: Int
    public let floorCount: Int
}

// MARK: - Converter

public enum RoomPlanConverter {
    private static var cancelledPlan: ConvertedFloorplan {
        ConvertedFloorplan(walls: [], rooms: [], furniture: [], width: 2, depth: 2,
            alignment: WorldAlignment(rotation: 0, offset: .zero, floorY: 0), routerPosition: nil, routerFloor: 0, floorCount: 1)
    }
    static let margin: Float = 0.3
    static let axisSnapTolerance: Float = 6 * .pi / 180
    static let weldDistance: Float = 0.12

    public static func convert(_ capture: RoomPlanCapture, profile: NetworkProfile = NetworkProfile()) -> ConvertedFloorplan {
        guard !Task.isCancelled else { return cancelledPlan }
        var usedSurfaceIDs = Set<String>()
        func nextUniqueID(_ raw: String, in used: inout Set<String>) -> String {
            let base = raw.isEmpty ? UUID().uuidString : raw
            if used.insert(base).inserted { return base }
            var index = 2
            while !used.insert("\(base)_\(index)").inserted { index += 1 }
            return "\(base)_\(index)"
        }
        let rawSurfaces = capture.surfaces.map { s in
            RoomPlanRawSurface(id: nextUniqueID(s.id, in: &usedSurfaceIDs), p1: s.p1, p2: s.p2, height: s.height, thickness: s.thickness, category: s.category, parentId: s.parentId, isOpen: s.isOpen, story: s.story)
        }
        // Stories → 0-based floors.
        let storyValues = Set(rawSurfaces.map(\.story) + capture.floors.map(\.story) + capture.objects.map(\.story)).sorted()
        let floorOf: (Int) -> Int = { story in storyValues.firstIndex(of: story) ?? 0 }
        let floorCount = max(1, storyValues.count)

        // 1. Rotate so the dominant wall direction lines up with the X axis.
        let wallSurfaces = rawSurfaces.filter { $0.category == "wall" }
        let rotation = -dominantAngle(of: wallSurfaces.isEmpty ? rawSurfaces : wallSurfaces)
        func rotated(_ p: SIMD2<Float>) -> SIMD2<Float> { Geometry.rotate(p, by: rotation) }

        var surfaces = rawSurfaces.map { s in
            snapToAxis(RoomPlanRawSurface(id: s.id, p1: rotated(s.p1), p2: rotated(s.p2), height: s.height, thickness: s.thickness, category: s.category, parentId: s.parentId, isOpen: s.isOpen, story: s.story))
        }
        var floorPolygons = capture.floors.map { f in (polygon: f.polygon.map(rotated), floor: floorOf(f.story)) }

        // 2. Translate into positive plan space with a small margin.
        var extentPoints = surfaces.flatMap { [$0.p1, $0.p2] } + floorPolygons.flatMap(\.polygon)
        if extentPoints.isEmpty { extentPoints = [.zero, SIMD2<Float>(4, 4)] }
        let (lo, hi) = Geometry.bounds(extentPoints)
        let offset = SIMD2<Float>(margin, margin) - lo
        surfaces = surfaces.map { s in
            RoomPlanRawSurface(id: s.id, p1: s.p1 + offset, p2: s.p2 + offset, height: s.height, thickness: s.thickness, category: s.category, parentId: s.parentId, isOpen: s.isOpen, story: s.story)
        }
        floorPolygons = floorPolygons.map { ($0.polygon.map { $0 + offset }, $0.floor) }
        let width = max(2, hi.x - lo.x + 2 * margin)
        let depth = max(2, hi.y - lo.y + 2 * margin)
        let validFloorY = capture.floorY.flatMap { $0.isFinite && abs($0) <= 10_000 ? $0 : nil } ?? 0
        var alignment = WorldAlignment(rotation: rotation, offset: offset, floorY: validFloorY)
        alignment.floorElevations = storyValues.enumerated().map { index, story in
            capture.floors.filter { $0.story == story }.map(\.y).filter { $0.isFinite && abs($0) <= 10_000 }.min() ?? (alignment.floorY + Float(index) * profile.floorHeight)
        }

        // 3. Close corners and T-junctions of structural walls.
        var walls = surfaces.filter { $0.category == "wall" }
        let openings = surfaces.filter { $0.category != "wall" }
        walls = weld(walls)
        guard !Task.isCancelled else { return cancelledPlan }

        // 4. Rooms from RoomPlan floors (labelled by sections), or a hull fallback.
        let sections = capture.sections.map { (kind: roomKind(forSection: $0.label), center: rotated($0.center) + offset, floor: floorOf($0.story)) }
        var rooms: [RoomInfo] = floorPolygons.compactMap { entry in
            guard entry.polygon.count >= 3, Geometry.area(entry.polygon) >= 0.5 else { return nil }
            let kind = sections.first { $0.floor == entry.floor && Geometry.contains(entry.polygon, $0.center) }?.kind ?? .other
            return RoomInfo(name: "", kind: kind, polygon: entry.polygon, floor: entry.floor)
        }
        // Regions enclosed by walls that RoomPlan did not report as floors (missing rooms would stay black).
        let barrierSegments = (walls + openings).map {
            RFWallSegment(id: $0.id, p1: $0.p1, p2: $0.p2, material: .drywall, kind: .wall, floor: floorOf($0.story))
        }
        rooms = ProjectRepair.completeRooms(existing: rooms, walls: barrierSegments, width: width, depth: depth, floorCount: floorCount, sections: sections)
        guard !Task.isCancelled else { return cancelledPlan }
        if rooms.isEmpty {
            for floor in 0..<floorCount {
                let points = walls.filter { floorOf($0.story) == floor }.flatMap { [$0.p1, $0.p2] }
                let hull = Geometry.convexHull(points)
                if hull.count >= 3 {
                    let kind = sections.first { $0.floor == floor }?.kind ?? .other
                    rooms.append(RoomInfo(name: "", kind: kind, polygon: hull, floor: floor))
                }
            }
        }
        rooms = RoomNaming.assignNames(rooms)

        // 5. Cut doors, windows and openings out of their parent walls.
        var segments: [RFWallSegment] = []
        var usedSegmentIDs = Set<String>()
        var intervalsByWall: [String: [(a: Float, b: Float, opening: RoomPlanRawSurface)]] = [:]
        var orphanOpenings: [RoomPlanRawSurface] = []
        for opening in openings {
            guard !Task.isCancelled else { return cancelledPlan }
            guard let parent = parentWall(for: opening, in: walls) else {
                orphanOpenings.append(opening)
                continue
            }
            let a = projection(of: opening.p1, onto: parent)
            let b = projection(of: opening.p2, onto: parent)
            intervalsByWall[parent.id, default: []].append((max(0, min(a, b)), min(1, max(a, b)), opening))
        }

        var counters: [WallKind: Int] = [:]
        func nextName(_ kind: WallKind) -> String {
            counters[kind, default: 0] += 1
            let n = counters[kind] ?? 1
            switch kind {
            case .wall: return "Wall \(n)"
            case .door: return "Door \(n)"
            case .window: return "Window \(n)"
            case .opening: return "Opening \(n)"
            case .obstacle: return "Object \(n)"
            }
        }

        for wall in walls {
            guard !Task.isCancelled else { return cancelledPlan }
            let floor = floorOf(wall.story)
            let exterior = isExterior(wall, rooms: rooms.filter { $0.floor == floor }, allWalls: walls)
            let wallMaterial = exterior ? profile.construction.exteriorMaterial : profile.construction.interiorMaterial
            let wallName = nextName(.wall)
            let intervals = (intervalsByWall[wall.id] ?? []).sorted { $0.a < $1.a }
            var cursor: Float = 0
            var piece = 0
            func emitWall(_ from: Float, _ to: Float) {
                guard (to - from) * simd_distance(wall.p1, wall.p2) > 0.02 else { return }
                piece += 1
                let rawID = piece == 1 ? wall.id : "\(wall.id)#\(piece)"
                segments.append(RFWallSegment(
                    id: nextUniqueID(rawID, in: &usedSegmentIDs),
                    name: wallName,
                    p1: point(on: wall, at: from),
                    p2: point(on: wall, at: to),
                    material: wallMaterial,
                    thickness: wallMaterial.defaultThickness,
                    height: wall.height,
                    kind: .wall,
                    floor: floor,
                    isExterior: exterior
                ))
            }
            for interval in intervals {
                let a = max(interval.a, cursor)
                let b = max(interval.b, a)
                emitWall(cursor, a)
                if (b - a) * simd_distance(wall.p1, wall.p2) > 0.05 {
                    let kind = openingKind(interval.opening)
                    let material = openingMaterial(interval.opening, exterior: exterior)
                    segments.append(RFWallSegment(
                        id: nextUniqueID(interval.opening.id, in: &usedSegmentIDs),
                        name: nextName(kind),
                        p1: point(on: wall, at: a),
                        p2: point(on: wall, at: b),
                        material: material,
                        thickness: material.defaultThickness,
                        height: interval.opening.height,
                        kind: kind,
                        floor: floor,
                        isExterior: exterior
                    ))
                }
                cursor = max(cursor, b)
            }
            emitWall(cursor, 1)
        }
        for opening in orphanOpenings {
            let kind = openingKind(opening)
            let material = openingMaterial(opening, exterior: false)
            segments.append(RFWallSegment(id: nextUniqueID(opening.id, in: &usedSegmentIDs), name: nextName(kind), p1: opening.p1, p2: opening.p2, material: material, thickness: material.defaultThickness, height: opening.height, kind: kind, floor: floorOf(opening.story)))
        }

        // 6. Objects: furniture for display, RF-relevant ones become obstacle boxes.
        var furniture: [FurnitureItem] = []
        var usedFurnitureIDs = Set<String>()
        var group: Int32 = 1000
        for object in capture.objects {
            guard !Task.isCancelled else { return cancelledPlan }
            let objectID = nextUniqueID(object.id, in: &usedFurnitureIDs)
            let center = rotated(object.position) + offset
            let yaw = object.yaw + rotation
            let floor = floorOf(object.story)
            furniture.append(FurnitureItem(id: objectID, category: object.category, position: center, size: object.dimensions, yaw: yaw, floor: floor))
            guard let material = obstacleMaterial(forCategory: object.category) else { continue }
            group += 1
            let corners = boxCorners(center: center, size: object.dimensions, yaw: yaw)
            let name = objectName(forCategory: object.category)
            for i in 0..<4 {
                segments.append(RFWallSegment(
                    id: nextUniqueID("\(objectID)#\(i)", in: &usedSegmentIDs),
                    name: name,
                    p1: corners[i],
                    p2: corners[(i + 1) % 4],
                    material: material,
                    thickness: 0.05,
                    height: 1,
                    objId: group,
                    kind: .obstacle,
                    floor: floor
                ))
            }
        }

        // 7. Router marker from the scan.
        var routerPosition: SIMD2<Float>?
        if let marker = capture.routerMarker {
            routerPosition = clampInside(rotated(marker) + offset, rooms: rooms.filter { $0.floor == floorOf(capture.routerMarkerStory) }, walls: segments)
        }

        return ConvertedFloorplan(
            walls: segments,
            rooms: rooms,
            furniture: furniture,
            width: width,
            depth: depth,
            alignment: alignment,
            routerPosition: routerPosition,
            routerFloor: floorOf(capture.routerMarkerStory),
            floorCount: floorCount
        )
    }

    // MARK: Orientation

    /// Length-weighted circular mean of wall angles modulo 90°.
    static func dominantAngle(of surfaces: [RoomPlanRawSurface]) -> Float {
        var sumC: Float = 0
        var sumS: Float = 0
        for s in surfaces {
            let d = s.p2 - s.p1
            let length = simd_length(d)
            guard length > 0.2 else { continue }
            let theta = atan2(d.y, d.x)
            sumC += length * cos(4 * theta)
            sumS += length * sin(4 * theta)
        }
        guard abs(sumC) + abs(sumS) > 1e-4 else { return 0 }
        return atan2(sumS, sumC) / 4
    }

    static func snapToAxis(_ s: RoomPlanRawSurface) -> RoomPlanRawSurface {
        let d = s.p2 - s.p1
        guard simd_length(d) > 0.05 else { return s }
        let angle = atan2(abs(d.y), abs(d.x))
        var p1 = s.p1
        var p2 = s.p2
        if angle < axisSnapTolerance {
            let z = (p1.y + p2.y) * 0.5
            p1.y = z
            p2.y = z
        } else if angle > .pi / 2 - axisSnapTolerance {
            let x = (p1.x + p2.x) * 0.5
            p1.x = x
            p2.x = x
        }
        return RoomPlanRawSurface(id: s.id, p1: p1, p2: p2, height: s.height, thickness: s.thickness, category: s.category, parentId: s.parentId, isOpen: s.isOpen, story: s.story)
    }

    // MARK: Welding

    /// Moves wall endpoints onto neighbouring corners (line intersection) or onto walls they almost touch.
    static func weld(_ input: [RoomPlanRawSurface]) -> [RoomPlanRawSurface] {
        var p1 = input.map(\.p1)
        var p2 = input.map(\.p2)
        let n = input.count
        func endpoint(_ i: Int, _ first: Bool) -> SIMD2<Float> { first ? p1[i] : p2[i] }
        func setEndpoint(_ i: Int, _ first: Bool, _ value: SIMD2<Float>) {
            if first { p1[i] = value } else { p2[i] = value }
        }

        for i in 0..<n {
            guard !Task.isCancelled else { return [] }
            for j in (i + 1)..<max(i + 1, n) where input[i].story == input[j].story {
                for first in [true, false] {
                    for second in [true, false] {
                        let a = endpoint(i, first)
                        let b = endpoint(j, second)
                        guard simd_distance(a, b) <= weldDistance else { continue }
                        var target = (a + b) * 0.5
                        if let hit = Geometry.intersection(p1[i], p2[i], p1[j], p2[j]) {
                            let point = p1[i] + (p2[i] - p1[i]) * hit.t
                            if simd_distance(point, a) <= weldDistance * 2 && simd_distance(point, b) <= weldDistance * 2 {
                                target = point
                            }
                        }
                        setEndpoint(i, first, target)
                        setEndpoint(j, second, target)
                    }
                }
            }
        }

        // T-junctions: extend an endpoint that stops just short of another wall.
        for i in 0..<n {
            guard !Task.isCancelled else { return [] }
            for first in [true, false] {
                let a = endpoint(i, first)
                for j in 0..<n where j != i && input[i].story == input[j].story {
                    let closest = Geometry.closestPoint(on: p1[j], p2[j], to: a)
                    let gap = simd_distance(closest, a)
                    guard gap > 1e-4, gap <= weldDistance else { continue }
                    let interior = simd_distance(closest, p1[j]) > 0.05 && simd_distance(closest, p2[j]) > 0.05
                    if interior { setEndpoint(i, first, closest) }
                }
            }
        }

        return input.indices.map { i in
            let s = input[i]
            return RoomPlanRawSurface(id: s.id, p1: p1[i], p2: p2[i], height: s.height, thickness: s.thickness, category: s.category, parentId: s.parentId, isOpen: s.isOpen, story: s.story)
        }.filter { simd_distance($0.p1, $0.p2) > 0.02 }
    }

    // MARK: Openings

    static func parentWall(for opening: RoomPlanRawSurface, in walls: [RoomPlanRawSurface]) -> RoomPlanRawSurface? {
        if let parentId = opening.parentId, let wall = walls.first(where: { $0.id == parentId }) {
            return wall
        }
        let mid = (opening.p1 + opening.p2) * 0.5
        let direction = simd_normalize(opening.p2 - opening.p1 + SIMD2<Float>(1e-6, 0))
        var best: RoomPlanRawSurface?
        var bestDistance: Float = 0.3
        for wall in walls where wall.story == opening.story {
            let wd = wall.p2 - wall.p1
            guard simd_length(wd) > 0.1 else { continue }
            let alignment = abs(simd_dot(simd_normalize(wd), direction))
            guard alignment > 0.97 else { continue }
            let t = projection(of: mid, onto: wall)
            guard t > -0.05, t < 1.05 else { continue }
            let distance = Geometry.distance(from: mid, toSegment: wall.p1, wall.p2)
            if distance < bestDistance {
                bestDistance = distance
                best = wall
            }
        }
        return best
    }

    static func projection(of p: SIMD2<Float>, onto wall: RoomPlanRawSurface) -> Float {
        let d = wall.p2 - wall.p1
        let length2 = simd_dot(d, d)
        guard length2 > 1e-8 else { return 0 }
        return simd_dot(p - wall.p1, d) / length2
    }

    static func point(on wall: RoomPlanRawSurface, at t: Float) -> SIMD2<Float> {
        wall.p1 + (wall.p2 - wall.p1) * t
    }

    static func openingKind(_ s: RoomPlanRawSurface) -> WallKind {
        switch s.category {
        case "door": return .door
        case "window": return .window
        default: return .opening
        }
    }

    static func openingMaterial(_ s: RoomPlanRawSurface, exterior: Bool) -> RFMaterial {
        switch s.category {
        case "door":
            if s.isOpen == false { return exterior ? .metalDoor : .woodenDoor }
            return .openDoor
        case "window":
            return .glass
        default:
            return .openDoor
        }
    }

    // MARK: Classification

    /// A wall is exterior when one side, just off its midpoint, lies outside every room of its floor.
    static func isExterior(_ wall: RoomPlanRawSurface, rooms: [RoomInfo], allWalls: [RoomPlanRawSurface]) -> Bool {
        let d = wall.p2 - wall.p1
        let length = simd_length(d)
        guard length > 1e-4 else { return false }
        let normal = SIMD2<Float>(-d.y, d.x) / length
        let mid = (wall.p1 + wall.p2) * 0.5
        if !rooms.isEmpty && rooms.contains(where: { $0.polygon.count >= 3 }) {
            let offsets: [Float] = [0.25, 0.4]
            for o in offsets {
                let inA = rooms.contains { $0.contains(mid + normal * o) }
                let inB = rooms.contains { $0.contains(mid - normal * o) }
                if inA != inB { return true }
                if inA && inB { return false }
            }
            return true
        }
        let points = allWalls.flatMap { [$0.p1, $0.p2] }
        let (lo, hi) = Geometry.bounds(points)
        let tolerance: Float = 0.35
        let onLeft = abs(wall.p1.x - lo.x) < tolerance && abs(wall.p2.x - lo.x) < tolerance
        let onRight = abs(wall.p1.x - hi.x) < tolerance && abs(wall.p2.x - hi.x) < tolerance
        let onTop = abs(wall.p1.y - lo.y) < tolerance && abs(wall.p2.y - lo.y) < tolerance
        let onBottom = abs(wall.p1.y - hi.y) < tolerance && abs(wall.p2.y - hi.y) < tolerance
        return onLeft || onRight || onTop || onBottom
    }

    public static func roomKind(forSection label: String) -> RoomKind {
        switch label {
        case "livingRoom": return .livingRoom
        case "kitchen": return .kitchen
        case "bedroom": return .bedroom
        case "bathroom": return .bathroom
        case "diningRoom": return .diningRoom
        default: return .other
        }
    }

    public static func obstacleMaterial(forCategory category: String) -> RFMaterial? {
        switch category {
        case "refrigerator", "oven", "dishwasher", "washerDryer", "stove": return .metal
        case "storage": return .wood
        case "fireplace": return .brick
        case "bathtub", "sink", "toilet": return .ceramic
        case "television": return .mirror
        default: return nil
        }
    }

    public static func objectName(forCategory category: String) -> String {
        switch category {
        case "refrigerator": return "Refrigerator"
        case "oven": return "Oven"
        case "dishwasher": return "Dishwasher"
        case "washerDryer": return "Washer/dryer"
        case "stove": return "Stove"
        case "storage": return "Cabinet"
        case "fireplace": return "Fireplace"
        case "bathtub": return "Bathtub"
        case "sink": return "Sink"
        case "toilet": return "Toilet"
        case "television": return "Television"
        case "bed": return "Bed"
        case "sofa": return "Sofa"
        case "table": return "Table"
        case "chair": return "Chair"
        case "stairs": return "Stairs"
        default: return "Object"
        }
    }

    static func boxCorners(center: SIMD2<Float>, size: SIMD2<Float>, yaw: Float) -> [SIMD2<Float>] {
        let hx = max(size.x, 0.1) * 0.5
        let hz = max(size.y, 0.1) * 0.5
        return [SIMD2<Float>(-hx, -hz), SIMD2<Float>(hx, -hz), SIMD2<Float>(hx, hz), SIMD2<Float>(-hx, hz)].map {
            center + Geometry.rotate($0, by: yaw)
        }
    }

    /// Keeps a node inside the home, off walls and outside furniture.
    public static func clampInside(_ point: SIMD2<Float>, rooms: [RoomInfo], walls: [RFWallSegment]) -> SIMD2<Float> {
        var p = point
        let valid = rooms.filter { $0.polygon.count >= 3 }
        if !valid.isEmpty, !valid.contains(where: { $0.contains(p) }) {
            var best = valid[0].labelPoint
            var bestDistance = Float.greatestFiniteMagnitude
            for room in valid {
                let label = room.labelPoint
                for i in 0..<room.polygon.count {
                    let edgePoint = Geometry.closestPoint(on: room.polygon[i], room.polygon[(i + 1) % room.polygon.count], to: p)
                    let d = simd_distance(edgePoint, p)
                    guard d < bestDistance else { continue }
                    let toLabel = label - edgePoint
                    let length = simd_length(toLabel)
                    let inward = length > 1e-4 ? edgePoint + toLabel / length * min(0.3, length) : label
                    bestDistance = d
                    best = inward
                }
            }
            p = best
        }
        return pushAwayFromWalls(p, walls: walls)
    }

    /// Moves a point at least 5 cm off any wall so it never sits on a wall line.
    public static func pushAwayFromWalls(_ point: SIMD2<Float>, walls: [RFWallSegment], clearance: Float = 0.05) -> SIMD2<Float> {
        var p = point
        for _ in 0..<3 {
            for w in walls where w.isActive && !w.material.isTransparent {
                let q = Geometry.closestPoint(on: w.p1, w.p2, to: p)
                let d = simd_distance(q, p)
                if d < clearance {
                    let away = d > 1e-5 ? (p - q) / d : w.normal
                    p = q + away * clearance
                }
            }
        }
        return p
    }
}
