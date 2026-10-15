import Foundation

public enum RFBand: String, CaseIterable, Codable, Sendable, Identifiable {
    case twoPointFour = "2.4"
    case five = "5"
    case six = "6"

    public var id: String { rawValue }

    /// Center frequency used for free-space loss (MHz).
    public var frequencyMhz: Float {
        switch self {
        case .twoPointFour: return 2437.0
        case .five: return 5200.0
        case .six: return 6105.0
        }
    }

    /// Free-space path loss at 1 m: 20·log10(f[MHz]) − 27.55.
    public var fspl1m: Float {
        20.0 * log10(frequencyMhz) - 27.55
    }

    public var gigahertz: Double {
        switch self {
        case .twoPointFour: return 2.4
        case .five: return 5
        case .six: return 6
        }
    }

    /// Locale-aware label such as "2,4 GHz" or "5 GHz".
    public var displayName: String {
        gigahertz.formatted(.number.precision(.fractionLength(0...1))) + " GHz"
    }
}
