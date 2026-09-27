import Foundation

public enum SignalGrade: String, CaseIterable, Codable, Sendable, Comparable {
    case none
    case poor
    case fair
    case good
    case excellent

    private var rank: Int {
        switch self {
        case .none: return 0
        case .poor: return 1
        case .fair: return 2
        case .good: return 3
        case .excellent: return 4
        }
    }

    public static func < (lhs: SignalGrade, rhs: SignalGrade) -> Bool { lhs.rank < rhs.rank }

    public var isCovered: Bool { self >= .good }
}

public struct RGBColor: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGBColor, _ t: Float) -> RGBColor {
        let k = max(0, min(1, t))
        return RGBColor(r + (other.r - r) * k, g + (other.g - g) * k, b + (other.b - b) * k)
    }
}

/// The single source of truth for signal thresholds, grades and heatmap colors.
public struct SignalScale: Equatable, Sendable {
    public static let excellentThreshold: Float = -55
    public static let fairThreshold: Float = -75
    public static let poorThreshold: Float = -85

    /// "Good" boundary, which is also the coverage threshold.
    public var coverageThreshold: Float
    public var palette: HeatmapPalette

    public init(coverageThreshold: Float = -67, palette: HeatmapPalette = .standard) {
        self.coverageThreshold = min(-58, max(-80, coverageThreshold))
        self.palette = palette
    }

    public init(profile: NetworkProfile) {
        self.init(coverageThreshold: profile.coverageThreshold, palette: profile.palette)
    }

    public static let `default` = SignalScale()

    public var excellent: Float { max(Self.excellentThreshold, coverageThreshold + 1) }
    public var fair: Float { min(Self.fairThreshold, coverageThreshold - 1) }
    public var poor: Float { Self.poorThreshold }

    public func grade(for rssi: Float) -> SignalGrade {
        if rssi >= excellent { return .excellent }
        if rssi >= coverageThreshold { return .good }
        if rssi >= fair { return .fair }
        if rssi >= poor { return .poor }
        return .none
    }

    /// RSSI used to pick the UI color of a grade, so badges match the heatmap.
    public func representativeRSSI(for grade: SignalGrade) -> Float {
        switch grade {
        case .excellent: return excellent + 5
        case .good: return (excellent + coverageThreshold) * 0.5
        case .fair: return (coverageThreshold + fair) * 0.5
        case .poor: return (fair + poor) * 0.5
        case .none: return poor - 6
        }
    }

    public func color(for grade: SignalGrade) -> RGBColor {
        color(for: representativeRSSI(for: grade))
    }

    /// Heatmap color. The ramp has a visible step exactly at the coverage threshold.
    public func color(for rssi: Float) -> RGBColor {
        let stops = colorStops
        guard let first = stops.first, let last = stops.last else { return RGBColor(0, 0, 0) }
        if rssi <= first.rssi { return first.color }
        if rssi >= last.rssi { return last.color }
        for i in 1..<stops.count where rssi <= stops[i].rssi {
            let a = stops[i - 1]
            let b = stops[i]
            let span = b.rssi - a.rssi
            return span <= 0 ? b.color : a.color.mixed(with: b.color, (rssi - a.rssi) / span)
        }
        return last.color
    }

    public var colorStops: [(rssi: Float, color: RGBColor)] {
        let t = coverageThreshold
        switch palette {
        case .standard:
            return [
                (poor - 10, RGBColor(0.22, 0.06, 0.12)),
                (poor, RGBColor(0.80, 0.16, 0.18)),
                (fair, RGBColor(0.96, 0.55, 0.16)),
                (t - 0.01, RGBColor(0.98, 0.84, 0.26)),
                (t, RGBColor(0.72, 0.86, 0.30)),
                (excellent, RGBColor(0.30, 0.74, 0.36)),
                (excellent + 10, RGBColor(0.08, 0.60, 0.42)),
                (excellent + 20, RGBColor(0.02, 0.45, 0.50))
            ]
        case .colorblindSafe:
            return [
                (poor - 10, RGBColor(0.27, 0.00, 0.33)),
                (poor, RGBColor(0.26, 0.23, 0.51)),
                (fair, RGBColor(0.16, 0.44, 0.56)),
                (t - 0.01, RGBColor(0.13, 0.57, 0.55)),
                (t, RGBColor(0.37, 0.79, 0.38)),
                (excellent, RGBColor(0.72, 0.87, 0.18)),
                (excellent + 10, RGBColor(0.90, 0.90, 0.14)),
                (excellent + 20, RGBColor(0.99, 0.95, 0.55))
            ]
        }
    }
}
