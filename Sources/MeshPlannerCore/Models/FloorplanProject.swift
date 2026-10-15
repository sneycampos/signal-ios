import Foundation
import simd

/// Maps RoomPlan world coordinates (meters, XZ plane) to plan coordinates and back.
public struct WorldAlignment: Codable, Equatable, Sendable {
    /// Rotation (radians) applied to world XZ before the offset.
    public var rotation: Float
    public var offset: SIMD2<Float>
    /// World-space height of the scanned floor, used to place the AR overlay.
    public var floorY: Float
    public var floorElevations: [Float]?

    public init(rotation: Float, offset: SIMD2<Float>, floorY: Float) {
        self.rotation = rotation
        self.offset = offset
        self.floorY = floorY
    }

    public func elevation(for floor: Int, floorHeight: Float) -> Float {
        if let floorElevations, floorElevations.indices.contains(floor) { return floorElevations[floor] }
        return floorY + Float(floor) * floorHeight
    }

    public func planPoint(worldX: Float, worldZ: Float) -> SIMD2<Float> {
        Geometry.rotate(SIMD2<Float>(worldX, worldZ), by: rotation) + offset
    }

    public func worldPoint(fromPlan point: SIMD2<Float>) -> SIMD2<Float> {
        Geometry.rotate(point - offset, by: -rotation)
    }
}

/// A user-entered signal reading used to calibrate the model.
public struct SignalMeasurement: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var position: SIMD2<Float>
    public var floor: Int
    public var band: RFBand
    public var rssi: Float
    public var date: Date

    public init(id: String = UUID().uuidString, position: SIMD2<Float>, floor: Int = 0, band: RFBand, rssi: Float, date: Date = Date()) {
        self.id = id
        self.position = position
        self.floor = floor
        self.band = band
        self.rssi = rssi
        self.date = date
    }
}

/// Model corrections fitted from real measurements.
public struct Calibration: Codable, Equatable, Sendable {
    public var pathLossExponent: Float
    public var wallLossScale: Float
    public var offsetDb: Float
    public var rmsErrorBefore: Float?
    public var rmsErrorAfter: Float?
    public var sampleCount: Int

    /// Indoor exponent for uncalibrated homes: free space is 2.0; furniture and people push real homes above it.
    public static let defaultPathLossExponent: Float = 2.5

    public init(pathLossExponent: Float = Calibration.defaultPathLossExponent, wallLossScale: Float = 1.0, offsetDb: Float = 0, rmsErrorBefore: Float? = nil, rmsErrorAfter: Float? = nil, sampleCount: Int = 0) {
        self.pathLossExponent = pathLossExponent
        self.wallLossScale = wallLossScale
        self.offsetDb = offsetDb
        self.rmsErrorBefore = rmsErrorBefore
        self.rmsErrorAfter = rmsErrorAfter
        self.sampleCount = sampleCount
    }

    public static let uncalibrated = Calibration()
    public var isCalibrated: Bool { sampleCount > 0 }
}

/// Furniture shown on the plan (RF-relevant objects are also converted into obstacle walls).
public struct FurnitureItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var category: String
    public var position: SIMD2<Float>
    public var size: SIMD2<Float>
    public var yaw: Float
    public var floor: Int

    public init(id: String = UUID().uuidString, category: String, position: SIMD2<Float>, size: SIMD2<Float>, yaw: Float = 0, floor: Int = 0) {
        self.id = id
        self.category = category
        self.position = position
        self.size = size
        self.yaw = yaw
        self.floor = floor
    }
}

public struct FloorplanProject: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public let id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDemo: Bool
    public var width: Float
    public var depth: Float
    public var walls: [RFWallSegment]
    public var accessPoints: [RFAccessPoint]
    public var rooms: [RoomInfo]
    public var furniture: [FurnitureItem]
    public var profile: NetworkProfile
    public var calibration: Calibration
    public var measurements: [SignalMeasurement]
    public var probe: SIMD2<Float>
    public var probeFloor: Int
    public var selectedBand: RFBand
    public var worldAlignment: WorldAlignment?
    public var floorCount: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDemo: Bool = false,
        width: Float,
        depth: Float,
        walls: [RFWallSegment],
        accessPoints: [RFAccessPoint],
        rooms: [RoomInfo],
        furniture: [FurnitureItem] = [],
        profile: NetworkProfile = NetworkProfile(),
        calibration: Calibration = .uncalibrated,
        measurements: [SignalMeasurement] = [],
        probe: SIMD2<Float>,
        probeFloor: Int = 0,
        selectedBand: RFBand = .five,
        worldAlignment: WorldAlignment? = nil,
        floorCount: Int = 1
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDemo = isDemo
        self.width = width
        self.depth = depth
        self.walls = walls
        self.accessPoints = accessPoints
        self.rooms = rooms
        self.furniture = furniture
        self.profile = profile
        self.calibration = calibration
        self.measurements = measurements
        self.probe = probe
        self.probeFloor = probeFloor
        self.selectedBand = selectedBand
        self.worldAlignment = worldAlignment
        self.floorCount = max(1, floorCount)
    }

    public var areaM2: Float { rooms.reduce(0) { $0 + $1.area } }
    public var router: RFAccessPoint? { accessPoints.first { !$0.isSatellite } }
    public var satellites: [RFAccessPoint] { accessPoints.filter(\.isSatellite) }

    public func rooms(onFloor floor: Int) -> [RoomInfo] { rooms.filter { $0.floor == floor } }

    public func room(containing point: SIMD2<Float>, floor: Int) -> RoomInfo? {
        rooms.first { $0.floor == floor && $0.contains(point) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, updatedAt, isDemo, width, depth, walls, accessPoints, rooms, furniture
        case profile, calibration, measurements, probe, probeFloor, selectedBand, worldAlignment, floorCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let walls = try c.decode([RFWallSegment].self, forKey: .walls)
        let width = (try c.decodeIfPresent(Float.self, forKey: .width)) ?? 10
        let depth = (try c.decodeIfPresent(Float.self, forKey: .depth)) ?? 10
        let decodedFloorCount = (try c.decodeIfPresent(Int.self, forKey: .floorCount)) ?? 1
        guard (1...32).contains(decodedFloorCount) else { throw ProjectStoreError.unreadableFile }
        self.init(
            id: (try c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try c.decodeIfPresent(String.self, forKey: .name)) ?? "Project",
            createdAt: (try c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(),
            updatedAt: (try c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date(),
            isDemo: (try c.decodeIfPresent(Bool.self, forKey: .isDemo)) ?? false,
            width: width,
            depth: depth,
            walls: walls,
            accessPoints: (try c.decodeIfPresent([RFAccessPoint].self, forKey: .accessPoints)) ?? [],
            rooms: (try c.decodeIfPresent([RoomInfo].self, forKey: .rooms)) ?? [],
            furniture: (try c.decodeIfPresent([FurnitureItem].self, forKey: .furniture)) ?? [],
            profile: (try c.decodeIfPresent(NetworkProfile.self, forKey: .profile)) ?? NetworkProfile(),
            calibration: (try c.decodeIfPresent(Calibration.self, forKey: .calibration)) ?? .uncalibrated,
            measurements: (try c.decodeIfPresent([SignalMeasurement].self, forKey: .measurements)) ?? [],
            probe: (try c.decodeIfPresent(SIMD2<Float>.self, forKey: .probe)) ?? SIMD2<Float>(width * 0.5, depth * 0.5),
            probeFloor: (try c.decodeIfPresent(Int.self, forKey: .probeFloor)) ?? 0,
            selectedBand: (try c.decodeIfPresent(RFBand.self, forKey: .selectedBand)) ?? .five,
            worldAlignment: try c.decodeIfPresent(WorldAlignment.self, forKey: .worldAlignment),
            floorCount: decodedFloorCount
        )
        schemaVersion = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        if !calibration.isCalibrated { calibration = .uncalibrated }
        try validate()
    }
}

// MARK: - Legacy (schema 1) migration

/// The format saved by earlier builds in `Documents/current_scan.json`.
struct LegacyScanState: Decodable {
    struct LegacyObject: Decodable {
        let id: String?
        let position: SIMD2<Float>
        let dimensions: SIMD2<Float>
        let category: String
    }

    let title: String
    let date: Date?
    let floorplanWidth: Float
    let floorplanDepth: Float
    let isCustomScan: Bool?
    let walls: [RFWallSegment]
    let accessPoints: [RFAccessPoint]
    let probePosition: SIMD2<Float>?
    let roomPolygon: [SIMD2<Float>]?
    let roomPolygons: [[SIMD2<Float>]]?
    let rawObjects: [LegacyObject]?
    let selectedBand: RFBand?

    func toProject() throws -> FloorplanProject {
        var polygons = roomPolygons ?? []
        if polygons.isEmpty, let single = roomPolygon, single.count >= 3 { polygons = [single] }
        let rooms = RoomNaming.assignNames(polygons.map { RoomInfo(name: "", kind: .other, polygon: $0) })
        var project = FloorplanProject(
            name: title,
            createdAt: date ?? Date(),
            updatedAt: date ?? Date(),
            width: floorplanWidth,
            depth: floorplanDepth,
            walls: walls,
            accessPoints: accessPoints,
            rooms: rooms,
            furniture: (rawObjects ?? []).map {
                FurnitureItem(id: $0.id ?? UUID().uuidString, category: $0.category, position: $0.position, size: $0.dimensions)
            },
            probe: probePosition ?? SIMD2<Float>(floorplanWidth * 0.5, floorplanDepth * 0.5),
            selectedBand: selectedBand ?? .five
        )
        project.schemaVersion = 1
        try project.validate()
        return ProjectRepair.upgradeIfNeeded(project)
    }
}
