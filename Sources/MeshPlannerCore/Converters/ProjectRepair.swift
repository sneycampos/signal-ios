import Foundation
import simd

/// Upgrades projects saved by earlier versions and completes room coverage.
public enum ProjectRepair {
    /// Projects below this schema get the full geometry repair.
    static let geometrySchema = 3

    public static func upgradeIfNeeded(_ project: FloorplanProject) -> FloorplanProject {
        guard project.schemaVersion < geometrySchema, !project.isDemo else { return project }
        var p = project
        // Earlier builds generated Portuguese names that embedded the old material ("Parede 3 (Brick (0.30 m))").
        var counters: [WallKind: Int] = [:]
        p.walls = cutOpenings(in: p.walls).map { wall in
            var w = wall
            guard w.kind != .obstacle else { return w }
            counters[w.kind, default: 0] += 1
            let n = counters[w.kind] ?? 1
            switch w.kind {
            case .wall: w.name = "Wall \(n)"
            case .door: w.name = "Door \(n)"
            case .window: w.name = "Window \(n)"
            case .opening: w.name = "Opening \(n)"
            case .obstacle: break
            }
            return w
        }
        p.accessPoints = p.accessPoints.map { ap in
            var a = ap
            if !a.isSatellite && a.name.hasPrefix("Roteador") { a.name = "Router" }
            if a.isSatellite, a.name.range(of: #"^(Sat.lite|Mesh Satellite) (\d+)$"#, options: .regularExpression) != nil,
               let number = a.name.split(separator: " ").last {
                a.name = "Satellite \(number)"
            }
            return a
        }
        if p.name.range(of: " Escaneado") != nil { p.name = "Scanned home" }
        let legacyRooms = p.rooms.allSatisfy { $0.kind == .other }
        let rebuilt = completeRooms(existing: legacyRooms ? [] : p.rooms, walls: p.walls, width: p.width, depth: p.depth, floorCount: p.floorCount, sections: [])
        if !rebuilt.isEmpty { p.rooms = rebuilt }
        p.walls = reclassify(p.walls, rooms: p.rooms, construction: p.profile.construction)
        p.schemaVersion = FloorplanProject.currentSchemaVersion
        return p
    }

    /// Splits structural walls where a door, window or opening overlaps them.
    public static func cutOpenings(in walls: [RFWallSegment]) -> [RFWallSegment] {
        let openings = walls.filter { $0.kind == .door || $0.kind == .window || $0.kind == .opening }
        guard !openings.isEmpty else { return walls }
        var result: [RFWallSegment] = []
        for wall in walls {
            guard wall.kind == .wall, wall.length > 0.05 else {
                result.append(wall)
                continue
            }
            let d = wall.p2 - wall.p1
            let length2 = simd_dot(d, d)
            let direction = d / sqrt(length2)
            var intervals: [(Float, Float)] = []
            for o in openings where o.floor == wall.floor {
                let od = o.p2 - o.p1
                guard simd_length(od) > 0.05, abs(simd_dot(simd_normalize(od), direction)) > 0.97 else { continue }
                guard Geometry.distance(from: o.midpoint, toSegment: wall.p1, wall.p2) < 0.15 else { continue }
                let a = simd_dot(o.p1 - wall.p1, d) / length2
                let b = simd_dot(o.p2 - wall.p1, d) / length2
                let lo = max(0, min(a, b)), hi = min(1, max(a, b))
                if hi - lo > 0.01 { intervals.append((lo, hi)) }
            }
            guard !intervals.isEmpty else {
                result.append(wall)
                continue
            }
            intervals.sort { $0.0 < $1.0 }
            var cursor: Float = 0
            var piece = 0
            func emit(_ a: Float, _ b: Float) {
                guard (b - a) * sqrt(length2) > 0.03 else { return }
                piece += 1
                let copy = RFWallSegment(id: piece == 1 ? wall.id : "\(wall.id)#\(piece)", name: wall.name, p1: wall.p1 + d * a, p2: wall.p1 + d * b, material: wall.material, thickness: wall.thickness, height: wall.height, isActive: wall.isActive, objId: wall.groupId, kind: .wall, floor: wall.floor, isExterior: wall.isExterior, isMaterialAuto: wall.isMaterialAuto)
                result.append(copy)
            }
            for (a, b) in intervals {
                if a > cursor { emit(cursor, a) }
                cursor = max(cursor, b)
            }
            if cursor < 1 { emit(cursor, 1) }
        }
        return result
    }

    /// Existing rooms plus any wall-enclosed region they do not cover.
    public static func completeRooms(existing: [RoomInfo], walls: [RFWallSegment], width: Float, depth: Float, floorCount: Int, sections: [(kind: RoomKind, center: SIMD2<Float>, floor: Int)]) -> [RoomInfo] {
        var rooms = existing
        for floor in 0..<max(1, floorCount) {
            let regions = RoomRegionDetector.regions(walls: walls, floor: floor, width: width, depth: depth)
            let onFloor = existing.filter { $0.floor == floor }
            for region in regions {
                if coveredFraction(region, by: onFloor) >= 0.5 { continue }
                let kind = sections.first { $0.floor == floor && Geometry.contains(region, $0.center) }?.kind ?? .other
                rooms.append(RoomInfo(name: "", kind: kind, polygon: region, floor: floor))
            }
        }
        let unnamed = rooms.enumerated().filter { $0.element.name.isEmpty }.map(\.offset)
        guard !unnamed.isEmpty else { return rooms }
        let named = RoomNaming.assignNames(rooms)
        for i in unnamed { rooms[i].name = named[i].name }
        return rooms
    }

    static func coveredFraction(_ polygon: [SIMD2<Float>], by rooms: [RoomInfo]) -> Float {
        guard !rooms.isEmpty else { return 0 }
        let (lo, hi) = Geometry.bounds(polygon)
        var total = 0
        var covered = 0
        let grid = FieldGrid.covering(width: hi.x - lo.x, depth: hi.y - lo.y, targetCell: 0.2, maxCells: 2_500)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let p = lo + grid.center(col: col, row: row)
                if Geometry.contains(polygon, p) {
                    total += 1
                    if rooms.contains(where: { $0.contains(p) }) { covered += 1 }
                }
            }
        }
        return total == 0 ? 1 : Float(covered) / Float(total)
    }

    /// Re-derives exterior/interior and automatic materials; old Low-E defaults on windows become clear glass.
    public static func reclassify(_ walls: [RFWallSegment], rooms: [RoomInfo], construction: ConstructionProfile) -> [RFWallSegment] {
        walls.map { wall in
            var w = wall
            let floorRooms = rooms.filter { $0.floor == wall.floor }
            if wall.kind == .wall || wall.kind == .window {
                w.isExterior = isExterior(wall, rooms: floorRooms)
            }
            guard wall.isMaterialAuto else { return w }
            switch wall.kind {
            case .wall:
                w.material = w.isExterior ? construction.exteriorMaterial : construction.interiorMaterial
                w.thickness = w.material.defaultThickness
            case .window where wall.material.id == RFMaterial.legacyGlass.id:
                w.material = .glass
            default:
                break
            }
            return w
        }
    }

    static func isExterior(_ wall: RFWallSegment, rooms: [RoomInfo]) -> Bool {
        guard !rooms.isEmpty else { return false }
        let n = wall.normal
        let mid = wall.midpoint
        for offset: Float in [0.25, 0.4] {
            let a = rooms.contains { $0.contains(mid + n * offset) }
            let b = rooms.contains { $0.contains(mid - n * offset) }
            if a != b { return true }
            if a && b { return false }
        }
        return true
    }
}
