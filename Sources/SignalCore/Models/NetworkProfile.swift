import Foundation

public enum WifiStandard: String, Codable, CaseIterable, Sendable, Identifiable {
    case wifi5
    case wifi6
    case wifi6E
    case wifi7

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wifi5: return "Wi-Fi 5 (802.11ac)"
        case .wifi6: return "Wi-Fi 6 (802.11ax)"
        case .wifi6E: return "Wi-Fi 6E"
        case .wifi7: return "Wi-Fi 7 (802.11be)"
        }
    }

    public var supportedBands: [RFBand] {
        switch self {
        case .wifi5, .wifi6: return [.twoPointFour, .five]
        case .wifi6E, .wifi7: return [.twoPointFour, .five, .six]
        }
    }

    /// Highest MCS index the standard reaches on a band.
    public func maxMCS(on band: RFBand) -> Int {
        switch self {
        case .wifi5: return band == .twoPointFour ? 7 : 9
        case .wifi6, .wifi6E: return 11
        case .wifi7: return 13
        }
    }
}

/// Default construction style used to classify scanned walls automatically.
public enum ConstructionProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case masonry
    case drywall
    case concrete

    public var id: String { rawValue }

    public var interiorMaterial: RFMaterial {
        switch self {
        case .masonry: return .masonryInterior
        case .drywall: return .drywall
        case .concrete: return .concrete
        }
    }

    public var exteriorMaterial: RFMaterial {
        switch self {
        case .masonry, .drywall: return .brick
        case .concrete: return .concrete
        }
    }
}

public enum HeatmapPalette: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard
    case colorblindSafe

    public var id: String { rawValue }
}

/// The user's equipment and preferences that drive link-rate and coverage estimates.
public struct NetworkProfile: Codable, Equatable, Sendable {
    public var standard: WifiStandard
    public var clientStreams: Int
    public var channelWidth24: Int
    public var channelWidth5: Int
    public var channelWidth6: Int
    /// Contracted internet speed (Mbps); 0 when unknown.
    public var internetPlanMbps: Int
    public var construction: ConstructionProfile
    /// RSSI (dBm) considered "good coverage".
    public var coverageThreshold: Float
    /// Tri-band mesh kits carry backhaul on a dedicated radio and do not halve throughput per hop.
    public var dedicatedBackhaulRadio: Bool
    public var backhaulBand: RFBand
    public var floorHeight: Float
    public var palette: HeatmapPalette

    public init(
        standard: WifiStandard = .wifi6,
        clientStreams: Int = 2,
        channelWidth24: Int = 20,
        channelWidth5: Int = 80,
        channelWidth6: Int = 160,
        internetPlanMbps: Int = 0,
        construction: ConstructionProfile = .masonry,
        coverageThreshold: Float = -67,
        dedicatedBackhaulRadio: Bool = false,
        backhaulBand: RFBand = .five,
        floorHeight: Float = 2.8,
        palette: HeatmapPalette = .standard
    ) {
        self.standard = standard
        self.clientStreams = clientStreams
        self.channelWidth24 = channelWidth24
        self.channelWidth5 = channelWidth5
        self.channelWidth6 = channelWidth6
        self.internetPlanMbps = internetPlanMbps
        self.construction = construction
        self.coverageThreshold = coverageThreshold
        self.dedicatedBackhaulRadio = dedicatedBackhaulRadio
        self.backhaulBand = backhaulBand
        self.floorHeight = floorHeight
        self.palette = palette
    }

    public var supportedBands: [RFBand] { standard.supportedBands }

    public func channelWidth(for band: RFBand) -> Int {
        switch band {
        case .twoPointFour: return channelWidth24
        case .five: return channelWidth5
        case .six: return channelWidth6
        }
    }

    /// Band used to decide router/satellite placement: 5 GHz carries most traffic and is the limiting band.
    public var planningBand: RFBand {
        supportedBands.contains(.five) ? .five : .twoPointFour
    }

    public var effectiveBackhaulBand: RFBand {
        supportedBands.contains(backhaulBand) ? backhaulBand : .five
    }

    private enum CodingKeys: String, CodingKey {
        case standard, clientStreams, channelWidth24, channelWidth5, channelWidth6, internetPlanMbps, construction
        case coverageThreshold, dedicatedBackhaulRadio, backhaulBand, floorHeight, palette
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NetworkProfile()
        self.init(
            standard: (try? c.decode(WifiStandard.self, forKey: .standard)) ?? d.standard,
            clientStreams: (try? c.decode(Int.self, forKey: .clientStreams)) ?? d.clientStreams,
            channelWidth24: (try? c.decode(Int.self, forKey: .channelWidth24)) ?? d.channelWidth24,
            channelWidth5: (try? c.decode(Int.self, forKey: .channelWidth5)) ?? d.channelWidth5,
            channelWidth6: (try? c.decode(Int.self, forKey: .channelWidth6)) ?? d.channelWidth6,
            internetPlanMbps: (try? c.decode(Int.self, forKey: .internetPlanMbps)) ?? d.internetPlanMbps,
            construction: (try? c.decode(ConstructionProfile.self, forKey: .construction)) ?? d.construction,
            coverageThreshold: (try? c.decode(Float.self, forKey: .coverageThreshold)) ?? d.coverageThreshold,
            dedicatedBackhaulRadio: (try? c.decode(Bool.self, forKey: .dedicatedBackhaulRadio)) ?? d.dedicatedBackhaulRadio,
            backhaulBand: (try? c.decode(RFBand.self, forKey: .backhaulBand)) ?? d.backhaulBand,
            floorHeight: (try? c.decode(Float.self, forKey: .floorHeight)) ?? d.floorHeight,
            palette: (try? c.decode(HeatmapPalette.self, forKey: .palette)) ?? d.palette
        )
    }
}
