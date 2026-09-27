import SwiftUI
import simd

/// Maps plan meters to view points and back.
struct PlanTransform: Equatable {
    var scale: CGFloat
    var origin: CGPoint

    static func fitting(width: Float, depth: Float, in size: CGSize, zoom: CGFloat, pan: CGSize, inset: CGFloat = 16) -> PlanTransform {
        let usable = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
        let fit = min(usable.width / CGFloat(max(width, 0.1)), usable.height / CGFloat(max(depth, 0.1)))
        let scale = fit * zoom
        let origin = CGPoint(
            x: (size.width - CGFloat(width) * scale) / 2 + pan.width,
            y: (size.height - CGFloat(depth) * scale) / 2 + pan.height
        )
        return PlanTransform(scale: scale, origin: origin)
    }

    func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
    }

    func plan(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2<Float>(Float((p.x - origin.x) / scale), Float((p.y - origin.y) / scale))
    }

    func length(_ meters: Float) -> CGFloat { CGFloat(meters) * scale }
    func meters(_ points: CGFloat) -> Float { Float(points / max(scale, 0.001)) }

    func path(_ polygon: [SIMD2<Float>]) -> Path {
        var path = Path()
        guard let first = polygon.first else { return path }
        path.move(to: point(first))
        for p in polygon.dropFirst() { path.addLine(to: point(p)) }
        path.closeSubpath()
        return path
    }
}
