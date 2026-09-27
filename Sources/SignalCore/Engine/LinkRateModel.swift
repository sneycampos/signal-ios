import Foundation

public struct LinkEstimate: Equatable, Sendable {
    public let snr: Float
    /// Highest usable MCS, nil when the link cannot be established.
    public let mcs: Int?
    /// PHY rate negotiated by the radios (Mbps).
    public let phyRateMbps: Float
    /// Expected application throughput (Mbps), roughly 60% of the PHY rate.
    public let throughputMbps: Float

    public static let none = LinkEstimate(snr: 0, mcs: nil, phyRateMbps: 0, throughputMbps: 0)
}

/// Converts RSSI into SNR, MCS, PHY rate and realistic throughput for a given equipment profile.
public enum LinkRateModel {
    public static let noiseFigure: Float = 7
    public static let macEfficiency: Float = 0.6

    /// Minimum SNR (dB) for MCS 0…13.
    static let mcsMinimumSNR: [Float] = [5, 8, 11, 14, 18, 22, 24, 26, 30, 32, 35, 37, 40, 42]
    /// Per-stream PHY rate at 20 MHz with 0.8 µs guard interval (802.11ax/be), MCS 0…13.
    static let perStreamRate20MHz: [Float] = [8.6, 17.2, 25.8, 34.4, 51.6, 68.8, 77.4, 86.0, 103.2, 114.7, 129.0, 143.4, 154.9, 172.1]

    public static func noiseFloor(channelWidthMHz: Int) -> Float {
        -174 + 10 * log10(Float(max(channelWidthMHz, 20)) * 1_000_000) + noiseFigure
    }

    public static func noiseFloor(for band: RFBand, profile: NetworkProfile) -> Float {
        noiseFloor(channelWidthMHz: profile.channelWidth(for: band))
    }

    static func widthFactor(_ width: Int) -> Float {
        switch width {
        case ..<40: return 1
        case 40..<80: return 2.0
        case 80..<160: return 4.19
        case 160..<320: return 8.37
        default: return 16.74
        }
    }

    public static func estimate(rssi: Float, band: RFBand, profile: NetworkProfile, streams: Int? = nil) -> LinkEstimate {
        let width = profile.channelWidth(for: band)
        let snr = rssi - noiseFloor(channelWidthMHz: width)
        let maxMCS = min(profile.standard.maxMCS(on: band), mcsMinimumSNR.count - 1)
        var mcs: Int?
        for index in stride(from: maxMCS, through: 0, by: -1) where snr >= mcsMinimumSNR[index] {
            mcs = index
            break
        }
        guard let usable = mcs else {
            return LinkEstimate(snr: snr, mcs: nil, phyRateMbps: 0, throughputMbps: 0)
        }
        let streamCount = Float(max(1, min(4, streams ?? profile.clientStreams)))
        let generationFactor: Float = profile.standard == .wifi5 ? 0.9 : 1.0
        let phy = perStreamRate20MHz[usable] * widthFactor(width) * streamCount * generationFactor
        return LinkEstimate(snr: snr, mcs: usable, phyRateMbps: phy, throughputMbps: phy * macEfficiency)
    }
}
