import Foundation

public enum BackhaulQuality: String, Sendable, Equatable {
    case wired
    case good
    case limit
    case weak

    /// Mesh vendors recommend satellites where the router's 5 GHz signal is around −65 to −70 dBm.
    public static func from(rssi: Float) -> BackhaulQuality {
        if rssi >= -65 { return .good }
        if rssi >= -70 { return .limit }
        return .weak
    }
}

public struct BackhaulLink: Equatable, Sendable {
    public let satelliteId: String
    public let parentId: String
    public let rssi: Float?
    public let hops: Int
    public let quality: BackhaulQuality
    /// Throughput available to clients of this satellite through its backhaul chain (Mbps).
    public let throughputMbps: Float
}

/// Builds the mesh backhaul tree: each wireless satellite links to the router or to the satellite
/// that gives it the strongest signal (widest-path tree, like Prim's algorithm).
public enum BackhaulPlanner {
    public static let wiredThroughput: Float = 940

    public static func plan(accessPoints: [RFAccessPoint], walls: [RFWallSegment], profile: NetworkProfile, calibration: Calibration = .uncalibrated) -> [String: BackhaulLink] {
        guard let router = accessPoints.first(where: { !$0.isSatellite && $0.isActive }) else { return [:] }
        let band = profile.effectiveBackhaulBand
        let model = PropagationModel(walls: walls, band: band, calibration: calibration, floorHeight: profile.floorHeight)
        let satellites = accessPoints.filter { $0.isSatellite && $0.isActive }

        var links: [String: BackhaulLink] = [:]
        var connected: [(ap: RFAccessPoint, throughput: Float, hops: Int)] = [(router, .greatestFiniteMagnitude, 0)]
        var pending: [RFAccessPoint] = []

        for sat in satellites {
            if sat.backhaul == .wired {
                links[sat.id] = BackhaulLink(satelliteId: sat.id, parentId: router.id, rssi: nil, hops: 1, quality: .wired, throughputMbps: wiredThroughput)
                connected.append((sat, wiredThroughput, 1))
            } else {
                pending.append(sat)
            }
        }

        while !pending.isEmpty {
            var best: (pendingIndex: Int, parent: Int, rssi: Float)?
            for (i, sat) in pending.enumerated() {
                for (j, node) in connected.enumerated() {
                    let value = model.rssi(from: node.ap, to: sat.position, floor: sat.floor)
                    if value > (best?.rssi ?? -.greatestFiniteMagnitude) {
                        best = (i, j, value)
                    }
                }
            }
            guard let choice = best else { break }
            let sat = pending.remove(at: choice.pendingIndex)
            let parent = connected[choice.parent]
            let link = LinkRateModel.estimate(rssi: choice.rssi, band: band, profile: profile, streams: 2).throughputMbps
            let hopFactor: Float = profile.dedicatedBackhaulRadio ? 1 : 0.5
            let throughput = min(parent.throughput, link) * hopFactor
            let hops = parent.hops + 1
            links[sat.id] = BackhaulLink(
                satelliteId: sat.id,
                parentId: parent.ap.id,
                rssi: choice.rssi,
                hops: hops,
                quality: BackhaulQuality.from(rssi: choice.rssi),
                throughputMbps: throughput
            )
            connected.append((sat, throughput, hops))
        }
        return links
    }
}
