import SwiftUI
import SignalCore

/// Thin color ramp with ticks at their true dBm positions; the coverage threshold is bold.
struct SignalLegend: View {
    let scale: SignalScale
    var printPalette = false
    @ScaledMetric(relativeTo: .caption2) private var tickHeight = 14
    private let low: Float = -95
    private let high: Float = -35

    var body: some View {
        VStack(spacing: 4) {
            LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
            GeometryReader { geo in
                ForEach(ticks, id: \.self) { value in
                    Text(Int(value).formatted())
                        .font(.caption2.monospacedDigit())
                        .fontWeight(value == scale.coverageThreshold ? .bold : .regular)
                        .foregroundStyle((printPalette ? Color.black : Color.white).opacity(value == scale.coverageThreshold ? 1 : 0.7))
                        .fixedSize()
                        .position(x: position(value) * geo.size.width, y: tickHeight / 2)
                }
            }
            .frame(height: tickHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map legend")
        .accessibilityValue(Text("Good signal from \(Format.dbm(scale.coverageThreshold)). Lower values indicate fair or weak signal."))
    }

    private var ticks: [Float] { [-85, -75, scale.coverageThreshold, -55, -45].sorted() }

    private func position(_ value: Float) -> CGFloat { CGFloat((value - low) / (high - low)) }

    private var gradientStops: [Gradient.Stop] {
        stride(from: low, through: high, by: 0.5).map { rssi in
            Gradient.Stop(color: Color(scale.color(for: rssi)), location: position(rssi))
        }
    }
}
