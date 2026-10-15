import Foundation

/// RF properties of a building material. Losses are per crossing at normal incidence.
public struct RFMaterial: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    /// Display name shown in the UI.
    public let name: String
    public let loss24: Float
    public let loss5: Float
    public let loss6: Float
    /// dB lost per specular bounce. Values ≥ 900 mean the surface does not reflect (open doorway).
    public let reflectionLoss: Float
    public let colorHex: String
    public let defaultThickness: Float

    public init(
        id: String,
        name: String,
        crossingLoss: [Float],
        reflectionLoss: Float,
        colorHex: String,
        defaultThickness: Float
    ) {
        let safe = RFMaterial.normalizedLosses(crossingLoss)
        self.init(id: id, name: name, loss24: safe[0], loss5: safe[1], loss6: safe[2], reflectionLoss: reflectionLoss, colorHex: colorHex, defaultThickness: defaultThickness)
    }

    public init(id: String, name: String, loss24: Float, loss5: Float, loss6: Float, reflectionLoss: Float, colorHex: String, defaultThickness: Float) {
        self.id = id
        self.name = name
        self.loss24 = max(0, loss24)
        self.loss5 = max(0, loss5)
        self.loss6 = max(0, loss6)
        self.reflectionLoss = reflectionLoss
        self.colorHex = colorHex
        self.defaultThickness = defaultThickness
    }

    public var crossingLoss: [Float] { [loss24, loss5, loss6] }

    public func crossingLoss(for band: RFBand) -> Float {
        switch band {
        case .twoPointFour: return loss24
        case .five: return loss5
        case .six: return loss6
        }
    }

    public var reflects: Bool { reflectionLoss < 900 }
    public var isTransparent: Bool { loss24 == 0 && loss5 == 0 && loss6 == 0 }

    /// Pads or trims an imported loss array to exactly three bands.
    static func normalizedLosses(_ values: [Float]) -> [Float] {
        guard let last = values.last else { return [0, 0, 0] }
        var result = Array(values.prefix(3))
        while result.count < 3 { result.append(last) }
        return result.map { $0.isFinite ? $0 : 0 }
    }
}

extension RFMaterial: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, crossingLoss, reflectionLoss, colorHex, defaultThickness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let losses = RFMaterial.normalizedLosses((try? c.decode([Float].self, forKey: .crossingLoss)) ?? [])
        self.init(
            id: id,
            name: (try? c.decode(String.self, forKey: .name)) ?? id,
            loss24: losses[0],
            loss5: losses[1],
            loss6: losses[2],
            reflectionLoss: (try? c.decode(Float.self, forKey: .reflectionLoss)) ?? 10,
            colorHex: (try? c.decode(String.self, forKey: .colorHex)) ?? "#9aa3ad",
            defaultThickness: (try? c.decode(Float.self, forKey: .defaultThickness)) ?? 0.12
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(crossingLoss, forKey: .crossingLoss)
        try c.encode(reflectionLoss, forKey: .reflectionLoss)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(defaultThickness, forKey: .defaultThickness)
    }
}

// MARK: - Catalog

extension RFMaterial {
    public static let drywall = RFMaterial(id: "drywall", name: "Drywall", loss24: 3, loss5: 4, loss6: 5, reflectionLoss: 10, colorHex: "#d9d4c7", defaultThickness: 0.10)
    public static let masonryInterior = RFMaterial(id: "masonry_interior", name: "Interior masonry (brick)", loss24: 5, loss5: 8, loss6: 10, reflectionLoss: 8, colorHex: "#c98a6b", defaultThickness: 0.15)
    public static let brick = RFMaterial(id: "brick", name: "Exterior masonry (30 cm)", loss24: 8, loss5: 12, loss6: 14, reflectionLoss: 7, colorHex: "#b5553a", defaultThickness: 0.30)
    public static let concrete = RFMaterial(id: "concrete", name: "Reinforced concrete", loss24: 18, loss5: 28, loss6: 33, reflectionLoss: 6, colorHex: "#7d7f82", defaultThickness: 0.25)
    public static let tiledDrywall = RFMaterial(id: "tiled_drywall", name: "Tiled wall", loss24: 5, loss5: 7, loss6: 8, reflectionLoss: 8, colorHex: "#b8c9cf", defaultThickness: 0.12)
    public static let glass = RFMaterial(id: "glass_clear", name: "Clear/double glass", loss24: 3, loss5: 5, loss6: 6, reflectionLoss: 6, colorHex: "#9fcbe3", defaultThickness: 0.02)
    public static let lowEGlass = RFMaterial(id: "glass_lowe", name: "Low-E (coated) glass", loss24: 20, loss5: 25, loss6: 28, reflectionLoss: 5, colorHex: "#5f9cc0", defaultThickness: 0.03)
    public static let woodenDoor = RFMaterial(id: "wooden_door", name: "Wooden door", loss24: 3, loss5: 4, loss6: 5, reflectionLoss: 12, colorHex: "#a0703c", defaultThickness: 0.05)
    public static let metalDoor = RFMaterial(id: "metal_door", name: "Metal/security door", loss24: 20, loss5: 25, loss6: 28, reflectionLoss: 3, colorHex: "#6f7780", defaultThickness: 0.06)
    public static let wood = RFMaterial(id: "wood", name: "Wooden furniture", loss24: 4, loss5: 6, loss6: 7, reflectionLoss: 10, colorHex: "#8b5a2b", defaultThickness: 0.40)
    public static let metal = RFMaterial(id: "metal", name: "Metal (appliance)", loss24: 30, loss5: 35, loss6: 38, reflectionLoss: 2, colorHex: "#9aa3ad", defaultThickness: 0.60)
    public static let mirror = RFMaterial(id: "mirror", name: "Mirror", loss24: 12, loss5: 15, loss6: 18, reflectionLoss: 2, colorHex: "#c7d2da", defaultThickness: 0.01)
    public static let water = RFMaterial(id: "water", name: "Water (aquarium)", loss24: 10, loss5: 15, loss6: 18, reflectionLoss: 9, colorHex: "#2f6fd1", defaultThickness: 0.40)
    public static let ceramic = RFMaterial(id: "ceramic", name: "Ceramic/bathtub", loss24: 2, loss5: 3, loss6: 4, reflectionLoss: 9, colorHex: "#e3e6ea", defaultThickness: 0.60)
    public static let floorSlab = RFMaterial(id: "floor_slab", name: "Concrete floor slab", loss24: 20, loss5: 28, loss6: 33, reflectionLoss: 6, colorHex: "#6d6f72", defaultThickness: 0.20)
    public static let openDoor = RFMaterial(id: "open_door", name: "Open doorway", loss24: 0, loss5: 0, loss6: 0, reflectionLoss: 999, colorHex: "#000000", defaultThickness: 0.05)
    public static let emptyContainer = RFMaterial(id: "empty_water", name: "Empty container", loss24: 0, loss5: 0, loss6: 0, reflectionLoss: 999, colorHex: "#94a3b8", defaultThickness: 0.40)

    /// Legacy Low-E entry used by older scans under the id "glass".
    static let legacyGlass = RFMaterial(id: "glass", name: "Low-E (coated) glass", loss24: 20, loss5: 25, loss6: 28, reflectionLoss: 5, colorHex: "#7fb6d6", defaultThickness: 0.03)

    /// Materials offered in the wall editor.
    public static let wallChoices: [RFMaterial] = [
        drywall, masonryInterior, brick, concrete, tiledDrywall, glass, lowEGlass, woodenDoor, metalDoor, mirror, openDoor
    ]

    /// Materials offered in the obstacle editor.
    public static let obstacleChoices: [RFMaterial] = [
        metal, wood, water, ceramic, mirror, openDoor
    ]

    public static let all: [RFMaterial] = [
        drywall, masonryInterior, brick, concrete, tiledDrywall, glass, lowEGlass, woodenDoor, metalDoor,
        wood, metal, mirror, water, ceramic, floorSlab, openDoor, emptyContainer
    ]

    public static let catalog: [String: RFMaterial] = {
        var map = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        map[legacyGlass.id] = legacyGlass
        return map
    }()
}
