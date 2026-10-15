import Foundation
import simd

/// Floorplan interchange document (the segment schema of the external web simulator, not part of this repository).
public struct SignalFloorplanDocument: Codable, Equatable, Sendable {
    public var version: String
    public var name: String
    public var timestamp: String
    public var dimensions: Dimensions
    public var materials: [MaterialEntry]
    public var walls: [WallEntry]
    public var accessPoints: [AccessPointEntry]

    public struct Dimensions: Codable, Equatable, Sendable {
        public var width: Float
        public var depth: Float
        public var wallHeight: Float
    }

    public struct MaterialEntry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var crossingLoss: [Float]
        public var reflectionLoss: Float
        public var color: String
    }

    public struct WallEntry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var p1: [Float]
        public var p2: [Float]
        public var materialId: String
        public var thickness: Float
        public var height: Float
        public var active: Bool
        public var objId: Int32
    }

    public struct AccessPointEntry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var x: Float
        public var z: Float
        public var txPower: Float
        public var isSatellite: Bool
    }
}

public enum SignalDataExporter {
    public static func document(from project: FloorplanProject) -> SignalFloorplanDocument {
        var materials: [String: RFMaterial] = [:]
        for wall in project.walls { materials[wall.material.id] = wall.material }
        return SignalFloorplanDocument(
            version: "2.0",
            name: project.name,
            timestamp: Date().formatted(.iso8601),
            dimensions: .init(width: project.width, depth: project.depth, wallHeight: project.walls.map(\.height).max() ?? 2.7),
            materials: materials.values.sorted { $0.id < $1.id }.map {
                .init(id: $0.id, name: $0.name, crossingLoss: $0.crossingLoss, reflectionLoss: $0.reflectionLoss, color: $0.colorHex)
            },
            walls: project.walls.filter { $0.floor == 0 }.map {
                .init(id: $0.id, name: $0.name, p1: [$0.p1.x, $0.p1.y], p2: [$0.p2.x, $0.p2.y], materialId: $0.material.id, thickness: $0.thickness, height: $0.height, active: $0.isActive, objId: $0.groupId)
            },
            accessPoints: project.accessPoints.filter { $0.floor == 0 }.map {
                .init(id: $0.id, name: $0.name, x: $0.position.x, z: $0.position.y, txPower: $0.txPower, isSatellite: $0.isSatellite)
            }
        )
    }

    public static func exportJSON(_ document: SignalFloorplanDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Rebuilds a project from a document, preferring the document's own material definitions.
    public static func project(from document: SignalFloorplanDocument, fallbackName: String) -> FloorplanProject {
        var materials = RFMaterial.catalog
        for entry in document.materials {
            materials[entry.id] = RFMaterial(id: entry.id, name: entry.name, crossingLoss: entry.crossingLoss, reflectionLoss: entry.reflectionLoss, colorHex: entry.color, defaultThickness: 0.12)
        }
        let walls: [RFWallSegment] = document.walls.compactMap { w in
            guard w.p1.count >= 2, w.p2.count >= 2 else { return nil }
            let material = materials[w.materialId] ?? .drywall
            return RFWallSegment(id: w.id, name: w.name, p1: SIMD2(w.p1[0], w.p1[1]), p2: SIMD2(w.p2[0], w.p2[1]), material: material, thickness: w.thickness, height: w.height, isActive: w.active, objId: w.objId, isMaterialAuto: false)
        }
        let aps = document.accessPoints.map {
            RFAccessPoint(id: $0.id, name: $0.name, position: SIMD2($0.x, $0.z), txPower: $0.txPower, isSatellite: $0.isSatellite)
        }
        let width = document.dimensions.width
        let depth = document.dimensions.depth
        return FloorplanProject(
            name: document.name.isEmpty ? fallbackName : document.name,
            width: width,
            depth: depth,
            walls: walls,
            accessPoints: aps,
            rooms: [],
            probe: SIMD2(width * 0.5, depth * 0.5)
        )
    }
}
