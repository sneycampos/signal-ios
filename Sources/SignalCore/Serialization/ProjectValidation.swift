import Foundation

extension FloorplanProject {
    /// Bounds shared by native imports, migrations and on-disk recovery, before any geometry work.
    func validate() throws {
        func bounded(_ x: Float, _ limit: Float = 10_000) -> Bool { x.isFinite && abs(x) <= limit }
        func point(_ p: SIMD2<Float>) -> Bool { bounded(p.x) && bounded(p.y) }
        func validFloor(_ f: Int) -> Bool { f >= 0 && f < floorCount }
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.count <= 256 } }
        guard (1...Self.currentSchemaVersion).contains(schemaVersion),
              !id.isEmpty, id.count <= 256, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              width.isFinite, depth.isFinite, width > 0, depth > 0, width <= 1_000, depth <= 1_000,
              (1...32).contains(floorCount), validFloor(probeFloor), point(probe),
              walls.count <= 10_000, rooms.count <= 512, accessPoints.count <= 64,
              furniture.count <= 5_000, measurements.count <= 10_000,
              unique(walls.map(\.id)), unique(rooms.map(\.id)), unique(accessPoints.map(\.id)),
              unique(furniture.map(\.id)), unique(measurements.map(\.id)),
              walls.allSatisfy({ w in
                  point(w.p1) && point(w.p2) && validFloor(w.floor) && bounded(w.height, 100) && bounded(w.thickness, 100)
                      && w.material.crossingLoss.allSatisfy { bounded($0, 1_000) }
                      && bounded(w.material.reflectionLoss, 10_000)
              }),
              rooms.allSatisfy({ validFloor($0.floor) && $0.polygon.count <= 2_048 && $0.polygon.allSatisfy(point) }),
              accessPoints.allSatisfy({ validFloor($0.floor) && point($0.position) && bounded($0.txPower, 100) }),
              furniture.allSatisfy({ validFloor($0.floor) && point($0.position) && point($0.size) && bounded($0.yaw) }),
              measurements.allSatisfy({ validFloor($0.floor) && point($0.position) && bounded($0.rssi, 200) }),
              bounded(profile.floorHeight, 100), profile.floorHeight > 0,
              bounded(profile.coverageThreshold, 200), (1...8).contains(profile.clientStreams),
              bounded(calibration.pathLossExponent, 10), calibration.pathLossExponent > 0,
              bounded(calibration.wallLossScale, 10), calibration.wallLossScale >= 0,
              bounded(calibration.offsetDb, 100) else { throw ProjectStoreError.unreadableFile }
        if let alignment = worldAlignment {
            guard bounded(alignment.rotation), point(alignment.offset), bounded(alignment.floorY),
                  (alignment.floorElevations?.count ?? 0) <= 32,
                  alignment.floorElevations?.allSatisfy({ bounded($0) }) != false else { throw ProjectStoreError.unreadableFile }
        }
    }
}
