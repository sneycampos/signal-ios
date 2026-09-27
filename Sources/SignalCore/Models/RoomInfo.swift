import Foundation
import simd

public enum RoomKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case livingRoom
    case kitchen
    case diningRoom
    case bedroom
    case office
    case bathroom
    case hallway
    case storage
    case other

    public var id: String { rawValue }

    /// Base name; numbered when repeated ("Bedroom 2").
    public var baseName: String {
        switch self {
        case .livingRoom: return "Living room"
        case .kitchen: return "Kitchen"
        case .diningRoom: return "Dining room"
        case .bedroom: return "Bedroom"
        case .office: return "Office"
        case .bathroom: return "Bathroom"
        case .hallway: return "Hallway"
        case .storage: return "Storage"
        case .other: return "Room"
        }
    }

    /// How much good coverage matters in this room for the optimizer.
    public var importance: Float {
        switch self {
        case .livingRoom, .office, .bedroom: return 1.0
        case .kitchen, .diningRoom, .other: return 0.8
        case .bathroom, .hallway: return 0.45
        case .storage: return 0.2
        }
    }
}

public struct RoomInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var kind: RoomKind
    public var polygon: [SIMD2<Float>]
    public var floor: Int

    public init(id: String = UUID().uuidString, name: String, kind: RoomKind, polygon: [SIMD2<Float>], floor: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.polygon = polygon
        self.floor = floor
    }

    public var area: Float { Geometry.area(polygon) }
    public var labelPoint: SIMD2<Float> { Geometry.labelPoint(polygon) }
    public func contains(_ point: SIMD2<Float>) -> Bool { Geometry.contains(polygon, point) }
}

/// Numbers repeated room names ("Bedroom", "Bedroom 2", …).
public enum RoomNaming {
    public static func assignNames(_ rooms: [RoomInfo]) -> [RoomInfo] {
        var counts: [RoomKind: Int] = [:]
        for room in rooms { counts[room.kind, default: 0] += 1 }
        var seen: [RoomKind: Int] = [:]
        return rooms.map { room in
            var copy = room
            let index = (seen[room.kind] ?? 0) + 1
            seen[room.kind] = index
            copy.name = (counts[room.kind] ?? 0) > 1 ? "\(room.kind.baseName) \(index)" : room.kind.baseName
            return copy
        }
    }
}
