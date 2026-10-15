import Foundation
import simd

/// A wall flattened for fast ray tests on one band.
struct PreparedWall: Sendable {
    let index: Int32
    let p1x: Float
    let p1z: Float
    let dx: Float
    let dz: Float
    let length: Float
    let nx: Float
    let nz: Float
    let loss: Float
    let reflectionLoss: Float
    let group: Int32
    let minX: Float
    let maxX: Float
    let minZ: Float
    let maxZ: Float
}

struct WallHit {
    var t: Float
    var loss: Float
    var group: Int32
    var index: Int32
}

/// Multi-wall indoor propagation model: free-space loss plus per-crossing wall losses (oblique factor capped at 2×),
/// one-bounce specular reflections, and slab losses between floors. Every map, number and optimizer in the app uses it.
public struct PropagationModel: Sendable {
    /// Distance from a ray end at which a wall is ignored (meters).
    static let endpointTolerance: Float = 0.01
    /// How far a wall is extended past its ends to close joints and small scan gaps (meters).
    static let jointExtension: Float = 0.015
    /// Crossings closer than this along a ray are one physical crossing (corner or joint).
    static let mergeDistance: Float = 0.03
    /// Reflections weaker than the direct path by more than this add less than 0.14 dB and are skipped.
    static let reflectionCutoff: Float = 15
    static let minimumDistance: Float = 0.5
    static let maxHits = 48

    public let band: RFBand
    public let calibration: Calibration
    public let floorHeight: Float
    let sourceWalls: [RFWallSegment]
    let blockersByFloor: [[PreparedWall]]
    let reflectorsByFloor: [[PreparedWall]]
    let slabLoss: Float

    public init(walls: [RFWallSegment], band: RFBand, calibration: Calibration = .uncalibrated, floorHeight: Float = 2.8) {
        self.band = band
        self.calibration = calibration
        self.floorHeight = floorHeight
        self.sourceWalls = walls
        self.slabLoss = RFMaterial.floorSlab.crossingLoss(for: band) * calibration.wallLossScale

        let floorCount = max(1, (walls.map(\.floor).filter { (0..<32).contains($0) }.max() ?? 0) + 1)
        var blockers = Array(repeating: [PreparedWall](), count: floorCount)
        var reflectors = Array(repeating: [PreparedWall](), count: floorCount)
        for (i, w) in walls.enumerated() where w.isActive && w.floor >= 0 && w.floor < floorCount {
            let d = w.p2 - w.p1
            let length = simd_length(d)
            guard length > 1e-4 else { continue }
            let prepared = PreparedWall(
                index: Int32(i),
                p1x: w.p1.x,
                p1z: w.p1.y,
                dx: d.x,
                dz: d.y,
                length: length,
                nx: -d.y / length,
                nz: d.x / length,
                loss: w.material.crossingLoss(for: band) * calibration.wallLossScale,
                reflectionLoss: w.material.reflectionLoss,
                group: w.groupId,
                minX: min(w.p1.x, w.p2.x),
                maxX: max(w.p1.x, w.p2.x),
                minZ: min(w.p1.y, w.p2.y),
                maxZ: max(w.p1.y, w.p2.y)
            )
            if prepared.loss > 0 { blockers[w.floor].append(prepared) }
            if w.material.reflects && length >= 0.3 { reflectors[w.floor].append(prepared) }
        }
        self.blockersByFloor = blockers
        self.reflectorsByFloor = reflectors
    }

    // MARK: Free space

    @inline(__always)
    public func freeSpaceLoss(distance: Float) -> Float {
        band.fspl1m + 10 * calibration.pathLossExponent * log10(max(distance, Self.minimumDistance))
    }

    /// Typical loss on the client side (phone antenna, hand/body) not covered by the geometry.
    public static let deviceMarginDb: Float = 3

    @inline(__always)
    func effectiveTx(_ ap: RFAccessPoint) -> Float { ap.txPower + calibration.offsetDb - Self.deviceMarginDb }

    // MARK: Wall crossings

    /// Total wall loss along a→b on one floor. Stops early once `budget` is exceeded.
    @inline(__always)
    func wallLoss(
        _ ax: Float, _ az: Float, _ bx: Float, _ bz: Float,
        floor: Int,
        excluding excluded: Int32 = -1,
        budget: Float = .greatestFiniteMagnitude,
        emit: ((WallHit) -> Void)? = nil
    ) -> Float {
        guard floor >= 0, floor < blockersByFloor.count else { return 0 }
        let rdx = bx - ax
        let rdz = bz - az
        let length2 = rdx * rdx + rdz * rdz
        guard length2 > 1e-8 else { return 0 }
        let length = length2.squareRoot()
        let invLength = 1 / length
        let tTolerance = Self.endpointTolerance * invLength
        let pad: Float = 0.02
        let loX = min(ax, bx) - pad
        let hiX = max(ax, bx) + pad
        let loZ = min(az, bz) - pad
        let hiZ = max(az, bz) + pad

        return blockersByFloor[floor].withUnsafeBufferPointer { walls in
            withUnsafeTemporaryAllocation(of: WallHit.self, capacity: Self.maxHits) { hits in
                var count = 0
                var total: Float = 0
                for w in walls {
                    if w.index == excluded { continue }
                    if w.maxX < loX || w.minX > hiX || w.maxZ < loZ || w.minZ > hiZ { continue }
                    let denom = rdx * w.dz - rdz * w.dx
                    if abs(denom) < 1e-9 { continue }
                    let qx = w.p1x - ax
                    let qz = w.p1z - az
                    let t = (qx * w.dz - qz * w.dx) / denom
                    if t <= tTolerance || t >= 1 - tTolerance { continue }
                    let u = (qx * rdz - qz * rdx) / denom
                    let uTolerance = Self.jointExtension / w.length
                    if u < -uTolerance || u > 1 + uTolerance { continue }

                    let cosTheta = abs(rdx * w.nx + rdz * w.nz) * invLength
                    let loss = w.loss * min(1 / max(cosTheta, 1e-4), 2)

                    // Faces of one obstacle count once; structural walls meeting at a joint or corner count once.
                    var merged = false
                    for k in 0..<count {
                        let sameObstacle = w.group != 0 && hits[k].group == w.group
                        let jointOrCorner = w.group == 0 && hits[k].group == 0 && abs(hits[k].t - t) * length < Self.mergeDistance
                        if sameObstacle || jointOrCorner {
                            if loss > hits[k].loss {
                                total += loss - hits[k].loss
                                hits[k].loss = loss
                                hits[k].index = w.index
                            }
                            merged = true
                            break
                        }
                    }
                    if !merged {
                        total += loss
                        if count < Self.maxHits {
                            hits[count] = WallHit(t: t, loss: loss, group: w.group, index: w.index)
                            count += 1
                        }
                    }
                    if total > budget { return total }
                }
                if let emit {
                    for k in 0..<count { emit(hits[k]) }
                }
                return total
            }
        }
    }

    // MARK: Direct path

    struct DirectPath {
        var rssi: Float
        var distance: Float
        var freeSpace: Float
        var walls: Float
        var slab: Float
    }

    @inline(__always)
    func direct(from ap: RFAccessPoint, to p: SIMD2<Float>, floor: Int, emit: ((WallHit) -> Void)? = nil) -> DirectPath {
        let dx = p.x - ap.position.x
        let dz = p.y - ap.position.y
        let planar2 = dx * dx + dz * dz
        let floors = abs(floor - ap.floor)
        var distance = planar2.squareRoot()
        var slab: Float = 0
        if floors > 0 {
            let vertical = Float(floors) * floorHeight
            distance = (planar2 + vertical * vertical).squareRoot()
            let cosTheta = vertical / max(distance, 1e-4)
            slab = slabLoss * Float(floors) * min(1 / max(cosTheta, 1e-4), 2)
        }
        let freeSpace = freeSpaceLoss(distance: distance)
        // Reciprocal approximation: each endpoint floor contributes half of the projected path.
        let walls: Float
        if floors > 0 {
            let scaledEmit: ((WallHit) -> Void)? = emit.map { callback in
                { hit in
                    var scaled = hit
                    scaled.loss *= 0.5
                    callback(scaled)
                }
            }
            walls = 0.5 * (wallLoss(ap.position.x, ap.position.y, p.x, p.y, floor: ap.floor, emit: scaledEmit)
                + wallLoss(ap.position.x, ap.position.y, p.x, p.y, floor: floor, emit: scaledEmit))
        } else {
            walls = wallLoss(ap.position.x, ap.position.y, p.x, p.y, floor: floor, emit: emit)
        }
        return DirectPath(rssi: effectiveTx(ap) - freeSpace - walls - slab, distance: distance, freeSpace: freeSpace, walls: walls, slab: slab)
    }

    // MARK: Reflections

    struct ReflectionHit {
        var wallIndex: Int32
        var point: SIMD2<Float>
        var rssi: Float
        var unfoldedDistance: Float
        var legLoss: Float
    }

    /// Power (mW) added by one-bounce specular reflections on the AP's own floor.
    @inline(__always)
    func reflectedPower(from ap: RFAccessPoint, to p: SIMD2<Float>, floor: Int, directRSSI: Float, emit: ((ReflectionHit) -> Void)? = nil) -> Float {
        guard floor == ap.floor, floor >= 0, floor < reflectorsByFloor.count else { return 0 }
        let ax = ap.position.x
        let az = ap.position.y
        let bx = p.x
        let bz = p.y
        let tx = effectiveTx(ap)
        let cutoff = max(directRSSI - Self.reflectionCutoff, -100)
        var power: Float = 0

        for w in reflectorsByFloor[floor] {
            let hS = (ax - w.p1x) * w.nx + (az - w.p1z) * w.nz
            let hR = (bx - w.p1x) * w.nx + (bz - w.p1z) * w.nz
            if hS * hR <= 1e-6 { continue }
            let sx = ax - 2 * hS * w.nx
            let sz = az - 2 * hS * w.nz
            let rdx = bx - sx
            let rdz = bz - sz
            let denom = rdx * w.dz - rdz * w.dx
            if abs(denom) < 1e-9 { continue }
            let qx = w.p1x - sx
            let qz = w.p1z - sz
            let t = (qx * w.dz - qz * w.dx) / denom
            if t <= 0.001 || t >= 0.999 { continue }
            let u = (qx * rdz - qz * rdx) / denom
            if u <= 0.001 || u >= 0.999 { continue }

            let unfolded = (rdx * rdx + rdz * rdz).squareRoot()
            let ceiling = tx - freeSpaceLoss(distance: unfolded) - w.reflectionLoss
            if ceiling < cutoff { continue }
            let budget = ceiling - cutoff
            let ix = sx + t * rdx
            let iz = sz + t * rdz
            let leg1 = wallLoss(ax, az, ix, iz, floor: floor, excluding: w.index, budget: budget)
            if leg1 >= budget { continue }
            let leg2 = wallLoss(ix, iz, bx, bz, floor: floor, excluding: w.index, budget: budget - leg1)
            let legs = leg1 + leg2
            if legs >= budget { continue }
            let rssi = ceiling - legs
            power += pow(10, rssi / 10)
            emit?(ReflectionHit(wallIndex: w.index, point: SIMD2<Float>(ix, iz), rssi: rssi, unfoldedDistance: unfolded, legLoss: legs))
        }
        return power
    }

    // MARK: Public API

    /// RSSI (dBm) from one AP, direct plus reflections.
    public func rssi(from ap: RFAccessPoint, to point: SIMD2<Float>, floor: Int, reflections: Bool = true) -> Float {
        let d = direct(from: ap, to: point, floor: floor)
        guard reflections else { return d.rssi }
        let extra = reflectedPower(from: ap, to: point, floor: floor, directRSSI: d.rssi)
        guard extra > 0 else { return d.rssi }
        return 10 * log10(pow(10, d.rssi / 10) + extra)
    }

    /// Best-server RSSI: a client associates with the strongest AP, powers are never summed across APs.
    public func best(from aps: [RFAccessPoint], to point: SIMD2<Float>, floor: Int, reflections: Bool = true) -> (rssi: Float, index: Int?) {
        var bestRSSI: Float = -200
        var bestIndex: Int?
        for (i, ap) in aps.enumerated() where ap.isActive {
            let value = rssi(from: ap, to: point, floor: floor, reflections: reflections)
            if value > bestRSSI {
                bestRSSI = value
                bestIndex = i
            }
        }
        return (bestRSSI, bestIndex)
    }

    /// Total loss (free space + walls + slab) between two points, used by the optimizer.
    public func pathLoss(from a: SIMD2<Float>, floorA: Int, to b: SIMD2<Float>, floorB: Int) -> Float {
        let probe = RFAccessPoint(id: "", name: "", position: a, txPower: 0, floor: floorA)
        return -direct(from: probe, to: b, floor: floorB).rssi + calibration.offsetDb
    }

    /// Full breakdown for the inspector. Uses exactly the same math as `rssi`.
    public func linkBudget(from ap: RFAccessPoint, to point: SIMD2<Float>, floor: Int, reflections: Bool = true) -> LinkBudget {
        var wallHits: [WallHit] = []
        let d = direct(from: ap, to: point, floor: floor) { wallHits.append($0) }
        var reflectionHits: [ReflectionHit] = []
        let extra = reflections ? reflectedPower(from: ap, to: point, floor: floor, directRSSI: d.rssi) { reflectionHits.append($0) } : 0
        let final = extra > 0 ? 10 * log10(pow(10, d.rssi / 10) + extra) : d.rssi

        let origin = ap.position
        let delta = point - origin
        let crossings = wallHits.sorted { $0.t < $1.t }.compactMap { hit -> RFWallCrossing? in
            guard Int(hit.index) < sourceWalls.count else { return nil }
            let wall = sourceWalls[Int(hit.index)]
            let cosTheta = abs(simd_dot(simd_normalize(delta), wall.normal))
            return RFWallCrossing(wall: wall, point: origin + delta * hit.t, loss: hit.loss, cosTheta: cosTheta)
        }
        let paths = reflectionHits.sorted { $0.rssi > $1.rssi }.compactMap { hit -> RFReflectionPath? in
            guard Int(hit.wallIndex) < sourceWalls.count else { return nil }
            return RFReflectionPath(reflectWall: sourceWalls[Int(hit.wallIndex)], reflPoint: hit.point, pathRSSI: hit.rssi, unfoldDist: hit.unfoldedDistance, legLoss: hit.legLoss)
        }
        return LinkBudget(
            accessPoint: ap,
            point: point,
            floor: floor,
            band: band,
            txPowerDbm: ap.txPower + calibration.offsetDb,
            deviceMarginDb: Self.deviceMarginDb,
            distanceMeters: d.distance,
            freeSpaceLossDb: d.freeSpace,
            wallLossDb: d.walls,
            floorLossDb: d.slab,
            directRssiDbm: d.rssi,
            crossings: crossings,
            reflections: paths,
            finalRssiDbm: final
        )
    }
}

/// Detailed link budget from one AP to one point.
public struct LinkBudget: Equatable, Sendable {
    public let accessPoint: RFAccessPoint
    public let point: SIMD2<Float>
    public let floor: Int
    public let band: RFBand
    public let txPowerDbm: Float
    public let deviceMarginDb: Float
    public let distanceMeters: Float
    public let freeSpaceLossDb: Float
    public let wallLossDb: Float
    public let floorLossDb: Float
    public let directRssiDbm: Float
    public let crossings: [RFWallCrossing]
    public let reflections: [RFReflectionPath]
    public let finalRssiDbm: Float

    public var reflectionGainDb: Float { max(0, finalRssiDbm - directRssiDbm) }
}

// MARK: - Convenience API (used by tests and tools)

public final class RFPropagationEngine: Sendable {
    public static let shared = RFPropagationEngine()

    public init() {}

    public func computeDirectPath(from ap: RFAccessPoint, to rx: SIMD2<Float>, band: RFBand, walls: [RFWallSegment]) -> RFDirectPathResult {
        let budget = PropagationModel(walls: walls, band: band).linkBudget(from: ap, to: rx, floor: ap.floor, reflections: false)
        return RFDirectPathResult(
            directRSSI: budget.directRssiDbm,
            fspl: budget.freeSpaceLossDb,
            dist: budget.distanceMeters,
            crossingLossTotal: budget.wallLossDb,
            crossings: budget.crossings
        )
    }

    public func computeReflectionPaths(from ap: RFAccessPoint, to rx: SIMD2<Float>, band: RFBand, walls: [RFWallSegment]) -> [RFReflectionPath] {
        PropagationModel(walls: walls, band: band).linkBudget(from: ap, to: rx, floor: ap.floor).reflections
    }

    public func getRSSI(at point: SIMD2<Float>, band: RFBand, accessPoints: [RFAccessPoint], walls: [RFWallSegment], reflectionsOn: Bool, floor: Int = 0) -> Float {
        PropagationModel(walls: walls, band: band).best(from: accessPoints, to: point, floor: floor, reflections: reflectionsOn).rssi
    }
}
