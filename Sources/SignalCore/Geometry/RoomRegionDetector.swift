import Foundation
import simd

/// Finds rooms as the regions enclosed by walls: walls, doors, windows and openings are rasterized as barriers,
/// the outside is flood-filled from the plan border, and every remaining connected region becomes a room outline.
public enum RoomRegionDetector {
    public static func regions(
        walls: [RFWallSegment],
        floor: Int,
        width: Float,
        depth: Float,
        cell: Float = 0.1,
        barrierRadius: Float = 0.12,
        minimumArea: Float = 1.2
    ) -> [[SIMD2<Float>]] {
        let barriers = walls.filter { $0.floor == floor && $0.isActive && $0.kind != .obstacle && $0.length > 0.05 }
        guard !barriers.isEmpty else { return [] }

        let pad = 3
        let origin = SIMD2<Float>(-Float(pad) * cell, -Float(pad) * cell)
        let cols = Int(ceil(width / cell)) + pad * 2
        let rows = Int(ceil(depth / cell)) + pad * 2
        var blocked = [Bool](repeating: false, count: cols * rows)

        func center(_ c: Int, _ r: Int) -> SIMD2<Float> {
            origin + SIMD2<Float>((Float(c) + 0.5) * cell, (Float(r) + 0.5) * cell)
        }

        for wall in barriers {
            let lo = simd_min(wall.p1, wall.p2) - barrierRadius - origin
            let hi = simd_max(wall.p1, wall.p2) + barrierRadius - origin
            let c0 = max(0, Int(lo.x / cell)), c1 = min(cols - 1, Int(hi.x / cell))
            let r0 = max(0, Int(lo.y / cell)), r1 = min(rows - 1, Int(hi.y / cell))
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in r0...r1 {
                for c in c0...c1 where !blocked[r * cols + c] {
                    if Geometry.distance(from: center(c, r), toSegment: wall.p1, wall.p2) <= barrierRadius {
                        blocked[r * cols + c] = true
                    }
                }
            }
        }

        // Outside: flood from the border.
        var label = [Int32](repeating: 0, count: cols * rows)
        let outside: Int32 = -1
        var queue: [Int] = []
        for c in 0..<cols {
            queue.append(c)
            queue.append((rows - 1) * cols + c)
        }
        for r in 0..<rows {
            queue.append(r * cols)
            queue.append(r * cols + cols - 1)
        }
        queue = queue.filter { !blocked[$0] }
        for i in queue { label[i] = outside }
        flood(&queue, label: &label, value: outside, blocked: blocked, cols: cols, rows: rows)

        // Interior components.
        var polygons: [[SIMD2<Float>]] = []
        var next: Int32 = 1
        let minCells = Int(minimumArea / (cell * cell))
        let growSteps = Int(ceil(barrierRadius / cell)) + 1
        for start in 0..<(cols * rows) where !blocked[start] && label[start] == 0 {
            let id = next
            next += 1
            label[start] = id
            var component = [start]
            var frontier = [start]
            flood(&frontier, label: &label, value: id, blocked: blocked, cols: cols, rows: rows, collect: &component)
            guard component.count >= minCells else { continue }

            // Grow into the wall band so the outline reaches the wall centerlines.
            var member = Set(component)
            var ring = component
            for _ in 0..<growSteps {
                var added: [Int] = []
                for i in ring {
                    let r = i / cols, c = i % cols
                    for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                        let j = nr * cols + nc
                        if blocked[j] && !member.contains(j) {
                            member.insert(j)
                            added.append(j)
                        }
                    }
                }
                ring = added
            }

            if let outline = outline(of: member, cols: cols, origin: origin, cell: cell) {
                polygons.append(outline)
            }
        }
        return polygons
    }

    private static func flood(_ queue: inout [Int], label: inout [Int32], value: Int32, blocked: [Bool], cols: Int, rows: Int) {
        var sink: [Int] = []
        flood(&queue, label: &label, value: value, blocked: blocked, cols: cols, rows: rows, collect: &sink)
    }

    private static func flood(_ queue: inout [Int], label: inout [Int32], value: Int32, blocked: [Bool], cols: Int, rows: Int, collect: inout [Int]) {
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let r = i / cols, c = i % cols
            if c > 0 { visit(i - 1) }
            if c < cols - 1 { visit(i + 1) }
            if r > 0 { visit(i - cols) }
            if r < rows - 1 { visit(i + cols) }
        }
        func visit(_ j: Int) {
            guard !blocked[j], label[j] == 0 else { return }
            label[j] = value
            queue.append(j)
            collect.append(j)
        }
    }

    /// Outer boundary of a cell set, traced along cell edges and simplified.
    static func outline(of cells: Set<Int>, cols: Int, origin: SIMD2<Float>, cell: Float) -> [SIMD2<Float>]? {
        struct Vertex: Hashable { let x: Int; let y: Int }
        var edges: [Vertex: [Vertex]] = [:]
        func add(_ a: Vertex, _ b: Vertex) { edges[a, default: []].append(b) }
        for i in cells {
            let r = i / cols, c = i % cols
            if !cells.contains(i - cols) || r == 0 { add(Vertex(x: c, y: r), Vertex(x: c + 1, y: r)) }
            if !cells.contains(i + 1) || c == cols - 1 { add(Vertex(x: c + 1, y: r), Vertex(x: c + 1, y: r + 1)) }
            if !cells.contains(i + cols) { add(Vertex(x: c + 1, y: r + 1), Vertex(x: c, y: r + 1)) }
            if !cells.contains(i - 1) || c == 0 { add(Vertex(x: c, y: r + 1), Vertex(x: c, y: r)) }
        }

        var loops: [[Vertex]] = []
        while let start = edges.first(where: { !$0.value.isEmpty })?.key {
            var loop = [start]
            var current = start
            while var outgoing = edges[current], !outgoing.isEmpty {
                let next = outgoing.removeLast()
                edges[current] = outgoing
                if next == start { break }
                loop.append(next)
                current = next
                if loop.count > cells.count * 4 + 8 { break }
            }
            if loop.count >= 4 { loops.append(loop) }
        }

        let points = loops.map { loop in loop.map { origin + SIMD2<Float>(Float($0.x), Float($0.y)) * cell } }
        guard let best = points.max(by: { Geometry.area($0) < Geometry.area($1) }) else { return nil }
        let simplified = simplify(best, tolerance: cell * 0.9)
        return simplified.count >= 3 ? simplified : nil
    }

    /// Douglas–Peucker on a closed polygon.
    static func simplify(_ polygon: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard polygon.count > 4 else { return polygon }
        // Split at the two mutually farthest points to simplify two open chains.
        let first = 0
        var far = 0
        var farDistance: Float = -1
        for (i, p) in polygon.enumerated() where simd_distance(p, polygon[first]) > farDistance {
            farDistance = simd_distance(p, polygon[first])
            far = i
        }
        func dp(_ pts: ArraySlice<SIMD2<Float>>) -> [SIMD2<Float>] {
            guard pts.count > 2, let a = pts.first, let b = pts.last else { return Array(pts) }
            var index = pts.startIndex
            var maxDistance: Float = 0
            for i in pts.indices.dropFirst().dropLast() {
                let d = Geometry.distance(from: pts[i], toSegment: a, b)
                if d > maxDistance { maxDistance = d; index = i }
            }
            guard maxDistance > tolerance else { return [a, b] }
            let left = dp(pts[pts.startIndex...index])
            let right = dp(pts[index...pts.index(before: pts.endIndex)])
            return left.dropLast() + right
        }
        let chainA = dp(polygon[first...far])
        let chainB = dp((polygon[far...] + [polygon[first]])[...])
        return Array(chainA.dropLast() + chainB.dropLast())
    }
}
