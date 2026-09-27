import Foundation
import simd

public enum BackhaulType: String, Codable, Sendable, CaseIterable {
    case wireless
    case wired
}

public struct RFAccessPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var position: SIMD2<Float>
    /// Transmit power (EIRP) in dBm.
    public var txPower: Float
    public var isSatellite: Bool
    public var isActive: Bool
    public var floor: Int
    public var backhaul: BackhaulType
    /// A locked node stays where it is (for example the router next to the fibre/cable outlet).
    public var isLocked: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        position: SIMD2<Float>,
        txPower: Float = 20.0,
        isSatellite: Bool = false,
        isActive: Bool = true,
        floor: Int = 0,
        backhaul: BackhaulType = .wireless,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.txPower = txPower
        self.isSatellite = isSatellite
        self.isActive = isActive
        self.floor = floor
        self.backhaul = backhaul
        self.isLocked = isLocked
    }
}

extension RFAccessPoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, position, txPower, isSatellite, isActive, floor, backhaul, isLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try? c.decode(String.self, forKey: .name)) ?? "Router",
            position: try c.decode(SIMD2<Float>.self, forKey: .position),
            txPower: (try? c.decode(Float.self, forKey: .txPower)) ?? 20,
            isSatellite: (try? c.decode(Bool.self, forKey: .isSatellite)) ?? false,
            isActive: (try? c.decode(Bool.self, forKey: .isActive)) ?? true,
            floor: (try? c.decode(Int.self, forKey: .floor)) ?? 0,
            backhaul: (try? c.decode(BackhaulType.self, forKey: .backhaul)) ?? .wireless,
            isLocked: (try? c.decode(Bool.self, forKey: .isLocked)) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(position, forKey: .position)
        try c.encode(txPower, forKey: .txPower)
        try c.encode(isSatellite, forKey: .isSatellite)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(floor, forKey: .floor)
        try c.encode(backhaul, forKey: .backhaul)
        try c.encode(isLocked, forKey: .isLocked)
    }
}
