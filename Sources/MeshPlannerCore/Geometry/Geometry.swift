import Foundation
import simd

public enum Geometry {
    public static func distance(from point: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_distance(point, closestPoint(on: a, b, to: point))
    }

    public static func closestPoint(on a: SIMD2<Float>, _ b: SIMD2<Float>, to point: SIMD2<Float>) -> SIMD2<Float> {
        let v = b - a
        let lengthSquared = simd_dot(v, v)
        guard lengthSquared > 1e-10 else { return a }
        let t = max(0, min(1, simd_dot(point - a, v) / lengthSquared))
        return a + t * v
    }

    /// Even-odd point-in-polygon test.
    public static func contains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let x = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var area: Float = 0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        return area * 0.5
    }

    public static func area(_ polygon: [SIMD2<Float>]) -> Float { abs(signedArea(polygon)) }

    public static func centroid(_ polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        let a = signedArea(polygon)
        guard abs(a) > 1e-6 else {
            return polygon.isEmpty ? .zero : polygon.reduce(.zero, +) / Float(polygon.count)
        }
        var c = SIMD2<Float>.zero
        for i in 0..<polygon.count {
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            let cross = p.x * q.y - q.x * p.y
            c += (p + q) * cross
        }
        return c / (6 * a)
    }

    /// A point well inside the polygon, suitable for a label (centroid when it lies inside).
    public static func labelPoint(_ polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        let c = centroid(polygon)
        guard polygon.count >= 3, !contains(polygon, c) else { return c }
        let (minP, maxP) = bounds(polygon)
        var best = c
        var bestClearance: Float = -1
        let steps = 24
        for i in 0...steps {
            for j in 0...steps {
                let p = SIMD2<Float>(
                    minP.x + (maxP.x - minP.x) * Float(i) / Float(steps),
                    minP.y + (maxP.y - minP.y) * Float(j) / Float(steps)
                )
                guard contains(polygon, p) else { continue }
                var clearance = Float.greatestFiniteMagnitude
                for k in 0..<polygon.count {
                    clearance = min(clearance, distance(from: p, toSegment: polygon[k], polygon[(k + 1) % polygon.count]))
                }
                if clearance > bestClearance {
                    bestClearance = clearance
                    best = p
                }
            }
        }
        return best
    }

    public static func bounds(_ points: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        guard var lo = points.first else { return (.zero, .zero) }
        var hi = lo
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    public static func rotate(_ p: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(p.x * c - p.y * s, p.x * s + p.y * c)
    }

    /// Convex hull (monotone chain), counter-clockwise.
    public static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Footprints of obstacle boxes (walls sharing a group id), as convex polygons.
    public static func obstacleFootprints(_ walls: [RFWallSegment], floor: Int) -> [[SIMD2<Float>]] {
        var groups: [Int32: [SIMD2<Float>]] = [:]
        for w in walls where w.groupId != 0 && w.floor == floor && w.isActive {
            groups[w.groupId, default: []].append(contentsOf: [w.p1, w.p2])
        }
        return groups.values.map { convexHull($0) }.filter { $0.count >= 3 }
    }

    /// Segment/segment intersection parameters (t along a→b, u along c→d); nil when parallel.
    public static func intersection(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> (t: Float, u: Float)? {
        let r = b - a
        let s = d - c
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-9 else { return nil }
        let ac = c - a
        let t = (ac.x * s.y - ac.y * s.x) / denom
        let u = (ac.x * r.y - ac.y * r.x) / denom
        return (t, u)
    }
}
