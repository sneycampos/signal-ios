import SwiftUI
import MeshPlannerCore

enum Theme {
    static let canvas = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let card = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.1)
    static let wall = Color.white.opacity(0.92)
    static let window = Color(red: 0.44, green: 0.72, blue: 0.91)
}

extension View {
    /// Frosted surface: Liquid Glass on iOS 26, material with a hairline on earlier versions.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        }
        #else
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        #endif
    }

    func cardSurface(cornerRadius: CGFloat = 24) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }
}

/// 44 pt circular glass icon button.
struct CircleIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(Circle())
        .accessibilityLabel(label)
    }
}

/// Coverage ring used on project cards.
struct CoverageRing: View {
    let percent: Float
    let color: Color
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Format.percent(percent))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Coverage \(Format.percent(percent))"))
    }
}

/// Semicircular signal gauge colored with the heatmap scale, with a needle at the current RSSI.
struct SignalGauge: View {
    let rssi: Float
    let scale: SignalScale
    private let low: Float = -95
    private let high: Float = -35

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height * 2)
            let radius = size / 2 - 12
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 4)
            let fraction = CGFloat(max(0, min(1, (rssi - low) / (high - low))))
            ZStack {
                Canvas { context, _ in
                    let steps = 60
                    for i in 0..<steps {
                        let a0 = Double.pi + Double(i) / Double(steps) * Double.pi
                        let a1 = Double.pi + Double(i + 1) / Double(steps) * Double.pi + 0.01
                        var arc = Path()
                        arc.addArc(center: center, radius: radius, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                        let value = low + (high - low) * Float(i) / Float(steps)
                        context.stroke(arc, with: .color(Color(scale.color(for: value))), style: StrokeStyle(lineWidth: 14, lineCap: i == 0 || i == steps - 1 ? .round : .butt))
                    }
                    let angle = Double.pi + Double(fraction) * Double.pi
                    let tip = CGPoint(x: center.x + CGFloat(cos(angle)) * (radius + 2), y: center.y + CGFloat(sin(angle)) * (radius + 2))
                    let base = CGPoint(x: center.x + CGFloat(cos(angle)) * (radius - 22), y: center.y + CGFloat(sin(angle)) * (radius - 22))
                    var needle = Path()
                    needle.move(to: base)
                    needle.addLine(to: tip)
                    context.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Capsule with the grade name, tinted with the grade color.
struct GradePill: View {
    let grade: SignalGrade
    let scale: SignalScale

    var body: some View {
        let color = scale.uiColor(for: grade)
        Text(grade.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
    }
}
