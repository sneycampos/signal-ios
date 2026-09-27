import SwiftUI
import SignalCore

extension Color {
    init(_ rgb: RGBColor) {
        self.init(.sRGB, red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b))
    }

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: UInt64
        switch cleaned.count {
        case 3: (r, g, b) = ((value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        case 6: (r, g, b) = (value >> 16, value >> 8 & 0xFF, value & 0xFF)
        default: (r, g, b) = (128, 128, 128)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension SignalScale {
    func uiColor(for grade: SignalGrade) -> Color { Color(color(for: grade)) }
    func uiColor(forRSSI rssi: Float) -> Color { Color(color(for: rssi)) }
}

extension SignalGrade {
    var title: LocalizedStringKey {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Weak"
        case .none: return "No signal"
        }
    }

    /// What the user can do with this signal.
    var usage: LocalizedStringKey {
        switch self {
        case .excellent: return "Great for 4K, games, and video calls"
        case .good: return "Good for HD streaming and video calls"
        case .fair: return "Browsing and messages; video may stutter"
        case .poor: return "Unstable: drops and slowdowns"
        case .none: return "No usable connection"
        }
    }

    var symbol: String {
        switch self {
        case .excellent: return "wifi"
        case .good: return "wifi"
        case .fair: return "wifi.exclamationmark"
        case .poor: return "wifi.exclamationmark"
        case .none: return "wifi.slash"
        }
    }
}

extension BackhaulQuality {
    var title: LocalizedStringKey {
        switch self {
        case .wired: return "Cable"
        case .good: return "Good"
        case .limit: return "At the limit"
        case .weak: return "Weak"
        }
    }

    var color: Color {
        switch self {
        case .wired: return .secondary
        case .good: return .green
        case .limit: return .yellow
        case .weak: return .red
        }
    }
}

enum Format {
    static func dbm(_ value: Float) -> String {
        "\(Int(value.rounded()).formatted()) dBm"
    }

    static func mbps(_ value: Float) -> String {
        let rounded = value >= 100 ? (value / 10).rounded() * 10 : value.rounded()
        return "\(Int(rounded).formatted()) Mbps"
    }

    static func percent(_ value: Float) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func meters(_ value: Float) -> String {
        Measurement(value: Double(value), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func area(_ value: Float) -> String {
        Measurement(value: Double(value), unit: UnitArea.squareMeters).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func decibels(_ value: Float) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) dB"
    }
}
