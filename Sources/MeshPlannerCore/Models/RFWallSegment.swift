import Foundation
import simd

public enum WallKind: String, Codable, Sendable, CaseIterable {
    case wall
    case door
    case window
    case opening
    case obstacle
}

public struct RFWallSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var p1: SIMD2<Float>
    public var p2: SIMD2<Float>
    public var material: RFMaterial
    public var thickness: Float
    public var height: Float
    public var isActive: Bool
    public var kind: WallKind
    /// Obstacle instance: faces of the same box share it and are counted once per ray. 0 = standalone surface.
    public var groupId: Int32
    public var floor: Int
    public var isExterior: Bool
    /// True while the material comes from automatic classification; false after a manual choice.
    public var isMaterialAuto: Bool

    public init(
        id: String = UUID().uuidString,
        name: String = "Wall",
        p1: SIMD2<Float>,
        p2: SIMD2<Float>,
        material: RFMaterial,
        thickness: Float = 0.12,
        height: Float = 2.7,
        isActive: Bool = true,
        objId: Int32 = 0,
        kind: WallKind? = nil,
        floor: Int = 0,
        isExterior: Bool = false,
        isMaterialAuto: Bool = true
    ) {
        self.id = id
        self.name = name
        self.p1 = p1
        self.p2 = p2
        self.material = material
        self.thickness = thickness
        self.height = height
        self.isActive = isActive
        self.groupId = objId
        self.kind = kind ?? RFWallSegment.inferKind(objId: objId, material: material)
        self.floor = floor
        self.isExterior = isExterior
        self.isMaterialAuto = isMaterialAuto
    }

    /// Legacy name for `groupId`.
    public var objId: Int32 { groupId }

    public var direction: SIMD2<Float> { p2 - p1 }
    public var length: Float { simd_length(direction) }
    public var midpoint: SIMD2<Float> { (p1 + p2) * 0.5 }

    public var normal: SIMD2<Float> {
        let len = length
        guard len > 1e-5 else { return SIMD2<Float>(0, 1) }
        let dir = direction
        return SIMD2<Float>(-dir.y / len, dir.x / len)
    }

    public func distance(to point: SIMD2<Float>) -> Float {
        Geometry.distance(from: point, toSegment: p1, p2)
    }

    static func inferKind(objId: Int32, material: RFMaterial) -> WallKind {
        if objId > 0 { return .obstacle }
        switch material.id {
        case RFMaterial.openDoor.id: return .opening
        case RFMaterial.woodenDoor.id, RFMaterial.metalDoor.id: return .door
        case RFMaterial.glass.id, RFMaterial.lowEGlass.id, RFMaterial.legacyGlass.id: return .window
        default: return .wall
        }
    }
}

extension RFWallSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, p1, p2, material, thickness, height, isActive, objId, groupId, kind, floor, isExterior, isMaterialAuto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let material = try c.decode(RFMaterial.self, forKey: .material)
        let group = try c.decodeIfPresent(Int32.self, forKey: .groupId) ?? c.decodeIfPresent(Int32.self, forKey: .objId) ?? 0
        self.init(
            id: (try c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try c.decodeIfPresent(String.self, forKey: .name)) ?? "Wall",
            p1: try c.decode(SIMD2<Float>.self, forKey: .p1),
            p2: try c.decode(SIMD2<Float>.self, forKey: .p2),
            material: material,
            thickness: (try c.decodeIfPresent(Float.self, forKey: .thickness)) ?? material.defaultThickness,
            height: (try c.decodeIfPresent(Float.self, forKey: .height)) ?? 2.7,
            isActive: (try c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true,
            objId: group,
            kind: try c.decodeIfPresent(WallKind.self, forKey: .kind),
            floor: (try c.decodeIfPresent(Int.self, forKey: .floor)) ?? 0,
            isExterior: (try c.decodeIfPresent(Bool.self, forKey: .isExterior)) ?? false,
            isMaterialAuto: (try c.decodeIfPresent(Bool.self, forKey: .isMaterialAuto)) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(p1, forKey: .p1)
        try c.encode(p2, forKey: .p2)
        try c.encode(material, forKey: .material)
        try c.encode(thickness, forKey: .thickness)
        try c.encode(height, forKey: .height)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(groupId, forKey: .objId)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(kind, forKey: .kind)
        try c.encode(floor, forKey: .floor)
        try c.encode(isExterior, forKey: .isExterior)
        try c.encode(isMaterialAuto, forKey: .isMaterialAuto)
    }
}
