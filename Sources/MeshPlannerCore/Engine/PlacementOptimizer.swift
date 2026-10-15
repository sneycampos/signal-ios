import Foundation
import simd

public enum SatelliteCountOption: Equatable, Sendable, Hashable {
    /// Evaluate 0…max satellites and recommend the smallest count that covers the home well.
    case automatic
    case exactly(Int)
}

public struct PlacementRequest: Sendable {
    public var walls: [RFWallSegment]
    public var rooms: [RoomInfo]
    public var accessPoints: [RFAccessPoint]
    public var profile: NetworkProfile
    public var calibration: Calibration
    public var width: Float
    public var depth: Float
    public var floor: Int
    public var satellites: SatelliteCountOption
    public var lockRouter: Bool
    public var maxSatellites: Int
    public var band: RFBand?

    public init(
        walls: [RFWallSegment],
        rooms: [RoomInfo],
        accessPoints: [RFAccessPoint],
        profile: NetworkProfile,
        calibration: Calibration = .uncalibrated,
        width: Float,
        depth: Float,
        floor: Int = 0,
        satellites: SatelliteCountOption = .automatic,
        lockRouter: Bool? = nil,
        maxSatellites: Int = 3,
        band: RFBand? = nil
    ) {
        self.walls = walls
        self.rooms = rooms
        self.accessPoints = accessPoints
        self.profile = profile
        self.calibration = calibration
        self.width = width
        self.depth = depth
        self.floor = floor
        self.satellites = satellites
        self.lockRouter = lockRouter ?? accessPoints.first(where: { !$0.isSatellite && $0.isActive })?.isLocked ?? false
        self.maxSatellites = maxSatellites
        self.band = band
    }
}

public struct PlacementProposal: Equatable, Sendable {
    public let routerPosition: SIMD2<Float>
    public let satellitePositions: [SIMD2<Float>]
    public let recommendedSatelliteCount: Int
    /// Estimated covered area for 0…N satellites (full propagation model, percent).
    public let estimatedCoverageBySatelliteCount: [Float]
    public let executionTimeMs: Double
}

/// Places the router and mesh satellites to maximize indoor coverage on the active band (with 1-bounce specular
/// reflections), keeping every wireless satellite within backhaul reach (≥ −70 dBm) of the router or another node.
public enum PlacementOptimizer {
    public static let minimumBackhaulRSSI: Float = -70
    public static let wallClearance: Float = 0.15
    static let maxEvalPoints = 960
    static let maxCandidates = 220
    static let candidateDedupeDistance: Float = 0.18
    /// Router-only search refines this many spatially diverse top candidates (plus the current position).
    static let routerSeedCount = 6
    static let routerSeedSpacing: Float = 1.0

    private struct EvalMetrics: Comparable {
        let coverage: Float
        let targetCoverage: Float
        let score: Float

        init(coverage: Float, targetCoverage: Float? = nil, score: Float) {
            self.coverage = coverage
            self.targetCoverage = targetCoverage ?? coverage
            self.score = score
        }

        static func < (lhs: EvalMetrics, rhs: EvalMetrics) -> Bool {
            if abs(lhs.coverage - rhs.coverage) > 0.20 {
                return lhs.coverage < rhs.coverage
            }
            return lhs.score < rhs.score
        }
    }

    public static func optimize(
        _ request: PlacementRequest,
        token: CancellationToken? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> PlacementProposal? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let router = request.accessPoints.first(where: { !$0.isSatellite && $0.isActive }) else { return nil }
        let floor = request.floor
        let profile = request.profile
        let threshold = profile.coverageThreshold
        let targetBand: RFBand = if let b = request.band, profile.supportedBands.contains(b) {
            b
        } else {
            profile.planningBand
        }
        let model = PropagationModel(walls: request.walls, band: targetBand, calibration: request.calibration, floorHeight: profile.floorHeight)
        let safeguardFiveModel: PropagationModel? = (targetBand == .twoPointFour && profile.supportedBands.contains(.five))
            ? PropagationModel(walls: request.walls, band: .five, calibration: request.calibration, floorHeight: profile.floorHeight)
            : nil
        let backhaulModel = PropagationModel(walls: request.walls, band: profile.effectiveBackhaulBand, calibration: request.calibration, floorHeight: profile.floorHeight)

        // 1. Uniform InteriorMask evaluation grid matching FloorplanViewModel.compare.
        let rooms = request.rooms.filter { $0.floor == floor && $0.polygon.count >= 3 }
        guard rooms.count <= maxEvalPoints else { return nil }
        let obstacles = Geometry.obstacleFootprints(request.walls, floor: floor)
        let floorWalls = request.walls.filter { $0.floor == floor && $0.isActive && !$0.material.isTransparent }

        let evalGrid = FieldGrid.covering(width: request.width, depth: request.depth, targetCell: 0.34, maxCells: maxEvalPoints)
        let evalMask = InteriorMask(grid: evalGrid, polygons: rooms.map(\.polygon))

        var evalPoints: [SIMD2<Float>] = []
        var evalWeights: [Float] = []
        var evalRoomIndices: [Int] = []
        var coarsePointIndices: [Int] = []
        evalPoints.reserveCapacity(min(maxEvalPoints, evalGrid.count))
        evalWeights.reserveCapacity(min(maxEvalPoints, evalGrid.count))
        evalRoomIndices.reserveCapacity(min(maxEvalPoints, evalGrid.count))

        var roomPointCounts = [Int](repeating: 0, count: rooms.count)
        for row in 0..<evalGrid.rows {
            for col in 0..<evalGrid.cols {
                let cell = row * evalGrid.cols + col
                guard evalMask.isInterior(cell), evalPoints.count < maxEvalPoints else { continue }
                let p = evalGrid.center(col: col, row: row)
                let rIdx = Int(evalMask.roomIndex[cell])
                let weight: Float = (!rooms.isEmpty && rIdx >= 0 && rIdx < rooms.count) ? rooms[rIdx].kind.importance : 1.0
                let ptIdx = evalPoints.count
                evalPoints.append(p)
                evalWeights.append(weight)
                evalRoomIndices.append(rIdx)
                if rIdx >= 0 && rIdx < rooms.count {
                    roomPointCounts[rIdx] += 1
                }
                if row % 2 == 0 && col % 2 == 0 {
                    coarsePointIndices.append(ptIdx)
                }
            }
        }

        // Sparse-room fallback for extreme synthetic bounds where small rooms fall between coarse grid centers.
        if !rooms.isEmpty {
            for (rIdx, room) in rooms.enumerated() where roomPointCounts[rIdx] == 0 {
                guard token?.isCancelled != true else { return nil }
                func appendFallbackPoint(_ p: SIMD2<Float>) {
                    guard evalPoints.count < maxEvalPoints, room.contains(p),
                          !obstacles.contains(where: { Geometry.contains($0, p) }) else { return }
                    let ptIdx = evalPoints.count
                    evalPoints.append(p)
                    evalWeights.append(room.kind.importance)
                    evalRoomIndices.append(rIdx)
                    coarsePointIndices.append(ptIdx)
                    roomPointCounts[rIdx] += 1
                }
                appendFallbackPoint(room.labelPoint)
                let (lo, hi) = Geometry.bounds(room.polygon)
                let span = max(0.1, min(hi.x - lo.x, hi.y - lo.y))
                let local = FieldGrid.covering(width: max(0.1, hi.x - lo.x), depth: max(0.1, hi.y - lo.y), targetCell: max(0.25, span / 3.0), maxCells: 9)
                for row in 0..<local.rows {
                    for col in 0..<local.cols {
                        appendFallbackPoint(lo + local.center(col: col, row: row))
                    }
                }
            }
        }
        if coarsePointIndices.count > 180 {
            let count = coarsePointIndices.count
            coarsePointIndices = (0..<180).map { coarsePointIndices[($0 * count) / 180] }
        } else if coarsePointIndices.count < min(64, evalPoints.count) {
            coarsePointIndices = Array(evalPoints.indices)
        }

        // 2. Rich decoupled candidate pool: current APs, room centers, doorway sightlines, and ~0.38 m interior grid.
        let existingSatellites = request.accessPoints
            .filter { $0.isSatellite && $0.floor == floor && $0.isActive }
            .sorted { ($0.isLocked ? 0 : 1, $0.backhaul == .wired ? 0 : 1) < ($1.isLocked ? 0 : 1, $1.backhaul == .wired ? 0 : 1) }

        func isInsideHome(_ p: SIMD2<Float>) -> Bool {
            rooms.isEmpty
                ? (p.x >= 0 && p.y >= 0 && p.x <= request.width && p.y <= request.depth)
                : rooms.contains { $0.contains(p) }
        }

        var candidates: [SIMD2<Float>] = []
        var isPriorityCandidate: [Bool] = []
        var isCurrentAPCandidate: [Bool] = []
        var candidateRoomIndices: [Int] = []
        candidates.reserveCapacity(maxCandidates)
        isPriorityCandidate.reserveCapacity(maxCandidates)
        isCurrentAPCandidate.reserveCapacity(maxCandidates)
        candidateRoomIndices.reserveCapacity(maxCandidates)

        func roomIndex(for p: SIMD2<Float>) -> Int {
            if let cell = evalGrid.cellIndex(for: p), evalMask.isInterior(cell) {
                let rIdx = Int(evalMask.roomIndex[cell])
                if rIdx >= 0 && rIdx < rooms.count { return rIdx }
            }
            return rooms.firstIndex { $0.contains(p) } ?? -1
        }

        // The shared pool must not depend on where the nodes currently are (otherwise the result depends on the
        // starting position), so current AP positions are appended last into reserved slots.
        let currentAPReserve = min(maxCandidates / 4, 2 * ((router.floor == floor ? 1 : 0) + existingSatellites.count))
        let poolCap = maxCandidates - currentAPReserve

        func addCandidate(_ p: SIMD2<Float>, priority: Bool, currentAP: Bool = false) {
            guard p.x.isFinite, p.y.isFinite, isInsideHome(p), isPlaceable(p, walls: floorWalls, obstacles: obstacles) else { return }
            let dedupeTol: Float = currentAP ? 1e-3 : candidateDedupeDistance
            if let existingIdx = candidates.firstIndex(where: { simd_distance($0, p) < dedupeTol }) {
                if priority { isPriorityCandidate[existingIdx] = true }
                if currentAP { isCurrentAPCandidate[existingIdx] = true }
                return
            }
            guard candidates.count < (currentAP ? maxCandidates : poolCap) else { return }
            candidates.append(p)
            isPriorityCandidate.append(priority)
            isCurrentAPCandidate.append(currentAP)
            candidateRoomIndices.append(roomIndex(for: p))
        }

        for room in rooms {
            for raw in [room.labelPoint, Geometry.centroid(room.polygon)] {
                let pushed = RoomPlanConverter.pushAwayFromWalls(raw, walls: floorWalls, clearance: wallClearance + 0.01)
                addCandidate(pushed, priority: true)
            }
        }

        let openings = request.walls.filter {
            $0.floor == floor && $0.isActive && ($0.kind == .door || $0.kind == .opening)
        }
        let sightlineOffsets: [Float] = [0.40, 0.75, 1.25]
        for op in openings {
            let anchor = op.midpoint
            for d in sightlineOffsets {
                for sign: Float in [-1.0, 1.0] {
                    let pt = RoomPlanConverter.pushAwayFromWalls(anchor + op.normal * (sign * d), walls: floorWalls, clearance: wallClearance + 0.01)
                    addCandidate(pt, priority: true)
                }
            }
        }
        if openings.count >= 2 {
            for i in 0..<openings.count {
                for j in (i + 1)..<openings.count where simd_distance(openings[i].midpoint, openings[j].midpoint) <= 6.0 {
                    let mid = RoomPlanConverter.pushAwayFromWalls(0.5 * (openings[i].midpoint + openings[j].midpoint), walls: floorWalls, clearance: wallClearance + 0.01)
                    addCandidate(mid, priority: true)
                }
            }
        }

        let candGrid = FieldGrid.covering(width: request.width, depth: request.depth, targetCell: 0.40, maxCells: 640)
        var rawGridCandidates: [SIMD2<Float>] = []
        rawGridCandidates.reserveCapacity(candGrid.count)
        for row in 0..<candGrid.rows {
            for col in 0..<candGrid.cols {
                let p = candGrid.center(col: col, row: row)
                if p.x.isFinite, p.y.isFinite, isInsideHome(p), isPlaceable(p, walls: floorWalls, obstacles: obstacles) {
                    rawGridCandidates.append(p)
                }
            }
        }
        let sparseReserve = min(32, rooms.count * 2)
        let gridTargetCap = max(candidates.count, poolCap - sparseReserve)
        let gridSlots = max(1, gridTargetCap - candidates.count)
        if rawGridCandidates.count <= gridSlots {
            for p in rawGridCandidates {
                addCandidate(p, priority: false)
            }
        } else {
            for s in 0..<gridSlots {
                let idx = (s * rawGridCandidates.count) / gridSlots
                addCandidate(rawGridCandidates[idx], priority: false)
            }
            for p in rawGridCandidates where candidates.count < gridTargetCap {
                addCandidate(p, priority: false)
            }
        }

        if !rooms.isEmpty {
            for (rIdx, room) in rooms.enumerated() where !candidateRoomIndices.contains(rIdx) {
                let (lo, hi) = Geometry.bounds(room.polygon)
                let span = max(0.1, min(hi.x - lo.x, hi.y - lo.y))
                let local = FieldGrid.covering(width: max(0.1, hi.x - lo.x), depth: max(0.1, hi.y - lo.y), targetCell: max(0.25, span / 3.0), maxCells: 9)
                for row in 0..<local.rows {
                    for col in 0..<local.cols {
                        let p = lo + local.center(col: col, row: row)
                        if room.contains(p) {
                            addCandidate(p, priority: true)
                            addCandidate(RoomPlanConverter.pushAwayFromWalls(p, walls: floorWalls, clearance: wallClearance + 0.01), priority: true)
                        }
                    }
                }
            }
        }

        if router.floor == floor {
            addCandidate(router.position, priority: true, currentAP: true)
            addCandidate(RoomPlanConverter.pushAwayFromWalls(router.position, walls: floorWalls, clearance: wallClearance + 0.01), priority: true, currentAP: true)
        }
        for sat in existingSatellites {
            addCandidate(sat.position, priority: true, currentAP: true)
            addCandidate(RoomPlanConverter.pushAwayFromWalls(sat.position, walls: floorWalls, clearance: wallClearance + 0.01), priority: true, currentAP: true)
        }

        guard !evalPoints.isEmpty, !candidates.isEmpty, token?.isCancelled != true else { return nil }

        // 3. Stage 1: Full-reflection screening on stride-2 coarsePointIndices across all candidates.
        let pointCount = evalPoints.count
        let coarseCount = coarsePointIndices.count
        let candidateCount = candidates.count
        let coarseAllocation = candidateCount.multipliedReportingOverflow(by: coarseCount)
        guard !coarseAllocation.overflow, coarseAllocation.partialValue <= maxCandidates * maxEvalPoints else { return nil }

        let utility = UtilityTable(threshold: threshold)
        let totalWeight = max(1e-5, evalWeights.reduce(0, +))
        let coarseWeights = coarsePointIndices.map { evalWeights[$0] }
        let coarseTotalWeight = max(1e-5, coarseWeights.reduce(0, +))
        let singleCellPct = 100.0 / Float(max(1, pointCount))

        let maxCount: Int
        switch request.satellites {
        case .automatic: maxCount = max(0, min(request.maxSatellites, 6))
        case .exactly(let n): maxCount = max(0, min(n, 6))
        }

        let routerTx = router.txPower + request.calibration.offsetDb
        let fixedAPs = request.accessPoints.filter { $0.isSatellite && $0.floor != floor && $0.isActive }
        var fixedBase = [Float](repeating: -200, count: pointCount)
        for ap in fixedAPs {
            for p in 0..<pointCount {
                let v = model.rssi(from: ap, to: evalPoints[p], floor: floor)
                if v > fixedBase[p] { fixedBase[p] = v }
            }
        }
        let fixedCoarseBase = coarsePointIndices.map { fixedBase[$0] }
        let fiveCoarseFixedBase: [Float]? = safeguardFiveModel.map { fiveModel in
            var base = [Float](repeating: -200, count: coarseCount)
            for ap in fixedAPs {
                for ci in 0..<coarseCount {
                    let v = fiveModel.rssi(from: ap, to: evalPoints[coarsePointIndices[ci]], floor: floor, reflections: false)
                    if v > base[ci] { base[ci] = v }
                }
            }
            return base
        }

        // Precompute cached 5 GHz coarse pathLoss rows across all candidates when safeguardFiveModel is active.
        var fiveCoarseLoss = [Float](repeating: 0, count: safeguardFiveModel != nil ? coarseAllocation.partialValue : 0)
        if let fiveModel = safeguardFiveModel {
            fiveCoarseLoss.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                let pts = evalPoints
                let cIndices = coarsePointIndices
                let cands = candidates
                DispatchQueue.concurrentPerform(iterations: candidateCount) { c in
                    if token?.isCancelled == true { return }
                    let origin = cands[c]
                    let baseOffset = c * coarseCount
                    for ci in 0..<coarseCount {
                        out[baseOffset + ci] = fiveModel.pathLoss(
                            from: origin, floorA: floor,
                            to: pts[cIndices[ci]], floorB: floor
                        )
                    }
                }
            }
        }
        var fiveArbitraryLossCache: [SIMD3<Int32>: [Float]] = [:]
        func fiveCoarseLossRow(for position: SIMD2<Float>, sourceFloor: Int) -> [Float]? {
            guard let fiveModel = safeguardFiveModel else { return nil }
            if token?.isCancelled == true { return nil }
            if sourceFloor == floor,
               let cIdx = candidates.firstIndex(where: { simd_distance($0, position) < 1e-3 }) {
                let offset = cIdx * coarseCount
                return Array(fiveCoarseLoss[offset..<(offset + coarseCount)])
            }
            let key = SIMD3<Int32>(
                Int32((position.x * 1000.0).rounded()),
                Int32((position.y * 1000.0).rounded()),
                Int32(sourceFloor)
            )
            if let cached = fiveArbitraryLossCache[key] {
                return cached
            }
            var row = [Float](repeating: 0, count: coarseCount)
            for ci in 0..<coarseCount {
                if token?.isCancelled == true { return nil }
                row[ci] = fiveModel.pathLoss(
                    from: position, floorA: sourceFloor,
                    to: evalPoints[coarsePointIndices[ci]], floorB: floor
                )
            }
            fiveArbitraryLossCache[key] = row
            return row
        }

        // Step 3: Compute full-reflection effectiveLoss across all candidates on coarsePointIndices.
        var coarseLoss = [Float](repeating: 0, count: coarseAllocation.partialValue)
        coarseLoss.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            let pts = evalPoints
            let cIndices = coarsePointIndices
            let cands = candidates
            let refTx = router.txPower
            DispatchQueue.concurrentPerform(iterations: candidateCount) { c in
                if token?.isCancelled == true { return }
                let origin = cands[c]
                let baseOffset = c * coarseCount
                for ci in 0..<coarseCount {
                    out[baseOffset + ci] = model.effectiveLoss(
                        from: origin, floorA: floor,
                        to: pts[cIndices[ci]], floorB: floor,
                        referenceTx: refTx, reflections: true
                    )
                }
            }
        }
        if token?.isCancelled == true { return nil }
        progress?(0.25)

        func satelliteTx(_ i: Int) -> Float {
            (i < existingSatellites.count ? existingSatellites[i].txPower : 20.0) + request.calibration.offsetDb
        }
        func satelliteIsWired(_ i: Int) -> Bool {
            i < existingSatellites.count && existingSatellites[i].backhaul == .wired
        }
        func satelliteIsLocked(_ i: Int) -> Bool {
            i < existingSatellites.count && existingSatellites[i].isLocked
        }

        func evaluateCoarseCandidate(_ c: Int, tx: Float, base: [Float], backhaulPenalty: Float = 0) -> EvalMetrics {
            let offset = c * coarseCount
            var covered = 0
            var softSum: Float = 0
            var weightedSum: Float = 0
            var strengthSum: Float = 0
            coarseLoss.withUnsafeBufferPointer { lossBuf in
                base.withUnsafeBufferPointer { baseBuf in
                    coarseWeights.withUnsafeBufferPointer { wBuf in
                        utility.values.withUnsafeBufferPointer { uBuf in
                            let uCount = uBuf.count
                            let uLow = utility.low
                            for ci in 0..<coarseCount {
                                let candR = tx - lossBuf[offset + ci]
                                let bR = baseBuf[ci]
                                let r = candR > bR ? candR : bR
                                if r >= threshold { covered += 1 }
                                let uIdx = Int((r - uLow) * 10)
                                let u = uIdx <= 0 ? uBuf[0] : (uIdx >= uCount ? uBuf[uCount - 1] : uBuf[uIdx])
                                softSum += u
                                weightedSum += wBuf[ci] * u
                                let clamped = r < -100 ? -100 : (r > -30 ? -30 : r)
                                strengthSum += clamped
                            }
                        }
                    }
                }
            }
            let invN = 1.0 / Float(coarseCount)
            let covPct = Float(covered) * invN * 100.0
            let meanStrength = (strengthSum * invN + 100.0) * (1.0 / 70.0)
            let j = covPct + 1.2 * (softSum * invN) + 0.4 * (weightedSum / coarseTotalWeight) + 0.15 * meanStrength - backhaulPenalty
            return EvalMetrics(coverage: covPct, score: j)
        }

        func evaluateCoarseLossRow(_ lossRow: [Float], tx: Float, base: [Float], backhaulPenalty: Float = 0) -> EvalMetrics {
            var covered = 0
            var softSum: Float = 0
            var weightedSum: Float = 0
            var strengthSum: Float = 0
            lossRow.withUnsafeBufferPointer { lossBuf in
                base.withUnsafeBufferPointer { baseBuf in
                    coarseWeights.withUnsafeBufferPointer { wBuf in
                        utility.values.withUnsafeBufferPointer { uBuf in
                            let uCount = uBuf.count
                            let uLow = utility.low
                            for ci in 0..<coarseCount {
                                let candR = tx - lossBuf[ci]
                                let bR = baseBuf[ci]
                                let r = candR > bR ? candR : bR
                                if r >= threshold { covered += 1 }
                                let uIdx = Int((r - uLow) * 10)
                                let u = uIdx <= 0 ? uBuf[0] : (uIdx >= uCount ? uBuf[uCount - 1] : uBuf[uIdx])
                                softSum += u
                                weightedSum += wBuf[ci] * u
                                let clamped = r < -100 ? -100 : (r > -30 ? -30 : r)
                                strengthSum += clamped
                            }
                        }
                    }
                }
            }
            let invN = 1.0 / Float(coarseCount)
            let covPct = Float(covered) * invN * 100.0
            let meanStrength = (strengthSum * invN + 100.0) * (1.0 / 70.0)
            let j = covPct + 1.2 * (softSum * invN) + 0.4 * (weightedSum / coarseTotalWeight) + 0.15 * meanStrength - backhaulPenalty
            return EvalMetrics(coverage: covPct, score: j)
        }

        func computeFiveSafeguard(router rPos: SIMD2<Float>, satellites sats: [SIMD2<Float>]) -> (coverage: Float, score: Float)? {
            guard safeguardFiveModel != nil, var best = fiveCoarseFixedBase else { return nil }
            guard let rLoss = fiveCoarseLossRow(for: rPos, sourceFloor: router.floor) else { return nil }
            for ci in 0..<coarseCount {
                let v = routerTx - rLoss[ci]
                if v > best[ci] { best[ci] = v }
            }
            for (i, sPos) in sats.enumerated() {
                guard let sLoss = fiveCoarseLossRow(for: sPos, sourceFloor: floor) else { return nil }
                let sTx = satelliteTx(i)
                for ci in 0..<coarseCount {
                    let v = sTx - sLoss[ci]
                    if v > best[ci] { best[ci] = v }
                }
            }
            var fiveCovered = 0
            var fiveSoft: Float = 0
            for ci in 0..<coarseCount {
                let r5 = best[ci]
                if r5 >= threshold { fiveCovered += 1 }
                fiveSoft += utility.value(r5)
            }
            let invN = 1.0 / Float(coarseCount)
            let fiveCov = Float(fiveCovered) * invN * 100.0
            return (fiveCov, fiveCov + 1.2 * (fiveSoft * invN))
        }

        func evaluateFull(_ best: [Float], backhaulPenalty: Float = 0, fiveSafeguard: (coverage: Float, score: Float)? = nil) -> EvalMetrics {
            var covered = 0
            var softSum: Float = 0
            var weightedSum: Float = 0
            var strengthSum: Float = 0
            best.withUnsafeBufferPointer { bestBuf in
                evalWeights.withUnsafeBufferPointer { wBuf in
                    utility.values.withUnsafeBufferPointer { uBuf in
                        let uCount = uBuf.count
                        let uLow = utility.low
                        for p in 0..<pointCount {
                            let r = bestBuf[p]
                            if r >= threshold { covered += 1 }
                            let uIdx = Int((r - uLow) * 10)
                            let u = uIdx <= 0 ? uBuf[0] : (uIdx >= uCount ? uBuf[uCount - 1] : uBuf[uIdx])
                            softSum += u
                            weightedSum += wBuf[p] * u
                            let clamped = r < -100 ? -100 : (r > -30 ? -30 : r)
                            strengthSum += clamped
                        }
                    }
                }
            }
            let invN = 1.0 / Float(pointCount)
            let rawCovPct = Float(covered) * invN * 100.0
            var covPct = rawCovPct
            let meanStrength = (strengthSum * invN + 100.0) * (1.0 / 70.0)
            var j = covPct + 1.2 * (softSum * invN) + 0.4 * (weightedSum / totalWeight) + 0.15 * meanStrength - backhaulPenalty
            if let fiveSafeguard {
                covPct = 0.65 * covPct + 0.35 * fiveSafeguard.coverage
                j = 0.65 * j + 0.35 * fiveSafeguard.score
            }
            return EvalMetrics(coverage: covPct, targetCoverage: rawCovPct, score: j)
        }

        func isBetter(_ candidate: EvalMetrics, than current: EvalMetrics, eps: Float = 1e-4) -> Bool {
            candidate.coverage > current.coverage + 1e-4
                || (candidate.coverage >= current.coverage - 1e-4 && candidate.score > current.score + eps)
        }

        // Stage 2: Upgrade current APs + priority candidates in top 28 + top 18 coarse candidates + top 2 per room to full pointCount reflection rows.
        var coarseLookup = [Int](repeating: -1, count: pointCount)
        for (ci, pIdx) in coarsePointIndices.enumerated() {
            coarseLookup[pIdx] = ci
        }

        var fullLossRows = [[Float]?](repeating: nil, count: candidateCount)
        let coarseLossSnapshot = coarseLoss

        func ensureFullRows(for indices: [Int]) {
            var seen = Set<Int>()
            let missing = indices.filter { c in
                guard c >= 0 && c < candidateCount && fullLossRows[c] == nil else { return false }
                return seen.insert(c).inserted
            }
            guard !missing.isEmpty else { return }
            var computed = [[Float]](repeating: [], count: missing.count)
            computed.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                let pts = evalPoints
                let cands = candidates
                let lookup = coarseLookup
                let refTx = router.txPower
                DispatchQueue.concurrentPerform(iterations: missing.count) { mIdx in
                    if token?.isCancelled == true { return }
                    let c = missing[mIdx]
                    let origin = cands[c]
                    let coarseOffset = c * coarseCount
                    var row = [Float](repeating: 0, count: pointCount)
                    for p in 0..<pointCount {
                        let ci = lookup[p]
                        if ci >= 0 {
                            row[p] = coarseLossSnapshot[coarseOffset + ci]
                        } else {
                            row[p] = model.effectiveLoss(
                                from: origin, floorA: floor,
                                to: pts[p], floorB: floor,
                                referenceTx: refTx, reflections: true
                            )
                        }
                    }
                    out[mIdx] = row
                }
            }
            if token?.isCancelled == true { return }
            for (mIdx, c) in missing.enumerated() {
                fullLossRows[c] = computed[mIdx]
            }
        }

        let singleCoarseRanking = (0..<candidateCount)
            .map { c in (c, evaluateCoarseCandidate(c, tx: routerTx, base: fixedCoarseBase)) }
            .sorted { $0.1 > $1.1 }

        var initialUpgrade: [Int] = []
        for c in 0..<candidateCount where isCurrentAPCandidate[c] {
            initialUpgrade.append(c)
        }
        for (c, _) in singleCoarseRanking.prefix(24) {
            initialUpgrade.append(c)
        }
        for (c, _) in singleCoarseRanking.prefix(40) where isPriorityCandidate[c] {
            initialUpgrade.append(c)
        }
        var spatiallyDiverseUpgrade: [SIMD2<Float>] = []
        for (c, _) in singleCoarseRanking {
            let p = candidates[c]
            if spatiallyDiverseUpgrade.allSatisfy({ simd_distance($0, p) >= 1.25 }) {
                initialUpgrade.append(c)
                spatiallyDiverseUpgrade.append(p)
                if spatiallyDiverseUpgrade.count >= 12 { break }
            }
        }
        if !rooms.isEmpty {
            var perRoomCount = [Int](repeating: 0, count: rooms.count)
            for (c, _) in singleCoarseRanking {
                let rIdx = candidateRoomIndices[c]
                if rIdx >= 0 && rIdx < rooms.count && perRoomCount[rIdx] < 2 {
                    initialUpgrade.append(c)
                    perRoomCount[rIdx] += 1
                }
            }
        }
        ensureFullRows(for: initialUpgrade)
        if token?.isCancelled == true { return nil }
        progress?(0.45)

        func row(candidate c: Int, tx: Float) -> [Float] {
            if fullLossRows[c] == nil {
                ensureFullRows(for: [c])
            }
            guard let lossRow = fullLossRows[c] else {
                return [Float](repeating: -200, count: pointCount)
            }
            var out = [Float](repeating: 0, count: pointCount)
            for p in 0..<pointCount { out[p] = tx - lossRow[p] }
            return out
        }

        func fullRow(at position: SIMD2<Float>, tx: Float, sourceFloor: Int? = nil) -> [Float] {
            let srcFloor = sourceFloor ?? floor
            if srcFloor == floor,
               let existingIdx = candidates.firstIndex(where: { simd_distance($0, position) < 1e-3 }),
               let lossRow = fullLossRows[existingIdx] {
                var out = [Float](repeating: 0, count: pointCount)
                for p in 0..<pointCount { out[p] = tx - lossRow[p] }
                return out
            }
            let refTx = router.txPower
            var out = [Float](repeating: 0, count: pointCount)
            out.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let outBuf = buffer
                let pts = evalPoints
                DispatchQueue.concurrentPerform(iterations: pointCount) { p in
                    if token?.isCancelled == true { return }
                    outBuf[p] = tx - model.effectiveLoss(from: position, floorA: srcFloor, to: pts[p], floorB: floor, referenceTx: refTx, reflections: true)
                }
            }
            return out
        }

        func combine(_ rows: [[Float]]) -> [Float] {
            var best = fixedBase
            for r in rows {
                for p in 0..<pointCount where r[p] > best[p] { best[p] = r[p] }
            }
            return best
        }

        func backhaulRSSI(from a: SIMD2<Float>, txA: Float, to b: SIMD2<Float>, sourceFloor: Int) -> Float {
            txA - backhaulModel.pathLoss(from: a, floorA: sourceFloor, to: b, floorB: floor)
        }

        func evaluateConnectivity(router r: SIMD2<Float>, satellites: [SIMD2<Float>]) -> (remaining: [Int], unreachedFixed: [RFAccessPoint]) {
            var reached = [SIMD2<Float>](arrayLiteral: r)
            var reachedTx = [routerTx]
            var reachedFloors = [router.floor]
            for ap in fixedAPs where ap.backhaul == .wired {
                reached.append(ap.position)
                reachedTx.append(ap.txPower + request.calibration.offsetDb)
                reachedFloors.append(ap.floor)
            }
            var remaining = Array(satellites.indices)
            var fixedPending = fixedAPs.filter { $0.backhaul != .wired }
            for i in remaining where satelliteIsWired(i) {
                reached.append(satellites[i])
                reachedTx.append(satelliteTx(i))
                reachedFloors.append(floor)
            }
            remaining.removeAll { satelliteIsWired($0) }
            var progressMade = true
            while progressMade {
                progressMade = false
                fixedPending.removeAll { ap in
                    guard reached.indices.contains(where: {
                        reachedTx[$0] - backhaulModel.pathLoss(from: reached[$0], floorA: reachedFloors[$0], to: ap.position, floorB: ap.floor) >= minimumBackhaulRSSI
                    }) else { return false }
                    reached.append(ap.position)
                    reachedTx.append(ap.txPower + request.calibration.offsetDb)
                    reachedFloors.append(ap.floor)
                    progressMade = true
                    return true
                }
                for i in remaining {
                    let ok = reached.indices.contains { backhaulRSSI(from: reached[$0], txA: reachedTx[$0], to: satellites[i], sourceFloor: reachedFloors[$0]) >= minimumBackhaulRSSI }
                    if ok {
                        reached.append(satellites[i])
                        reachedTx.append(satelliteTx(i))
                        reachedFloors.append(floor)
                        remaining.removeAll { $0 == i }
                        progressMade = true
                    }
                }
            }
            return (remaining, fixedPending)
        }

        let initialUnreachedFixed = Set(evaluateConnectivity(router: router.position, satellites: []).unreachedFixed.map(\.id))
        let requiredFixedIDs = Set(fixedAPs.filter { $0.backhaul != .wired && !initialUnreachedFixed.contains($0.id) }.map(\.id))
        let lockedTargetSatellites = Array(existingSatellites.prefix(maxCount).filter(\.isLocked).map(\.position))
        let lockedTargetInitiallyConnected = !lockedTargetSatellites.isEmpty
            && evaluateConnectivity(router: router.position, satellites: lockedTargetSatellites).remaining.isEmpty

        /// Every wireless satellite must reach the router through a chain of links ≥ −70 dBm.
        func isConnected(router r: SIMD2<Float>, satellites: [SIMD2<Float>]) -> Bool {
            let result = evaluateConnectivity(router: r, satellites: satellites)
            if !result.remaining.isEmpty || result.unreachedFixed.contains(where: { requiredFixedIDs.contains($0.id) }) {
                return false
            }
            if lockedTargetInitiallyConnected && satellites.count < lockedTargetSatellites.count {
                let extraLocked = Array(lockedTargetSatellites.dropFirst(satellites.count))
                return evaluateConnectivity(router: r, satellites: satellites + extraLocked).remaining.isEmpty
            }
            return true
        }

        func backhaulPenalty(router r: SIMD2<Float>, satellites: [SIMD2<Float>]) -> Float {
            guard !satellites.isEmpty else { return 0 }
            var reachedPos: [SIMD2<Float>] = [r]
            var reachedTx: [Float] = [routerTx]
            var reachedFloors: [Int] = [router.floor]
            var reachedHops: [Int] = [0]

            for ap in fixedAPs where ap.backhaul == .wired {
                reachedPos.append(ap.position)
                reachedTx.append(ap.txPower + request.calibration.offsetDb)
                reachedFloors.append(ap.floor)
                reachedHops.append(0)
            }
            var remaining: [Int] = []
            for i in satellites.indices {
                if satelliteIsWired(i) {
                    reachedPos.append(satellites[i])
                    reachedTx.append(satelliteTx(i))
                    reachedFloors.append(floor)
                    reachedHops.append(0)
                } else {
                    remaining.append(i)
                }
            }
            var penalty: Float = 0
            while !remaining.isEmpty {
                var bestIdxInRemaining = -1
                var bestLinkRSSI: Float = -200
                var bestParentHops = 0
                for (rIdx, satIdx) in remaining.enumerated() {
                    let satPos = satellites[satIdx]
                    for parent in reachedPos.indices {
                        // reachedTx already includes calibration.offsetDb (like routerTx/satelliteTx); effectiveLoss
                        // adds it back to its reference, so pass the raw power to get exactly the link RSSI.
                        let tx = reachedTx[parent]
                        let linkRSSI = tx - backhaulModel.effectiveLoss(
                            from: reachedPos[parent], floorA: reachedFloors[parent],
                            to: satPos, floorB: floor,
                            referenceTx: tx - request.calibration.offsetDb, reflections: true
                        )
                        if linkRSSI > bestLinkRSSI {
                            bestLinkRSSI = linkRSSI
                            bestIdxInRemaining = rIdx
                            bestParentHops = reachedHops[parent]
                        }
                    }
                }
                guard bestIdxInRemaining >= 0 else { break }
                let satIdx = remaining.remove(at: bestIdxInRemaining)
                let hops = bestParentHops + 1
                reachedPos.append(satellites[satIdx])
                reachedTx.append(satelliteTx(satIdx))
                reachedFloors.append(floor)
                reachedHops.append(hops)

                penalty += max(0, (-60.0 - bestLinkRSSI) * 0.008)
                if hops > 1 && !profile.dedicatedBackhaulRadio {
                    penalty += 0.06 * Float(hops - 1)
                }
            }
            return penalty
        }

        let compassDirs: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
            SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1)
        ]

        func compassRefineNode(
            nodeIndex: Int,
            nodes: inout [SIMD2<Float>],
            rows: inout [[Float]],
            steps: [Float],
            maxIterationsPerStep: Int = 3
        ) {
            let tx = nodeIndex == 0 ? routerTx : satelliteTx(nodeIndex - 1)
            let base = combine(rows.enumerated().filter { $0.offset != nodeIndex }.map(\.element))
            let coarseBase = coarsePointIndices.map { base[$0] }
            var bestPos = nodes[nodeIndex]
            var bestRow = rows[nodeIndex]
            let initialSats = Array(nodes.dropFirst())
            let initialPen = backhaulPenalty(router: nodes[0], satellites: initialSats)
            let initialFive = computeFiveSafeguard(router: nodes[0], satellites: initialSats)
            var bestMetrics = evaluateFull(combine([base, bestRow]), backhaulPenalty: initialPen, fiveSafeguard: initialFive)
            var currentCoarseLoss = coarsePointIndices.map { tx - bestRow[$0] }
            var currentCoarseScore = evaluateCoarseLossRow(currentCoarseLoss, tx: tx, base: coarseBase, backhaulPenalty: initialPen).score

            for step in steps {
                for _ in 0..<maxIterationsPerStep {
                    if token?.isCancelled == true { return }
                    var validProbes: [SIMD2<Float>] = []
                    validProbes.reserveCapacity(8)
                    for dir in compassDirs {
                        let p = bestPos + dir * step
                        guard isInsideHome(p), isPlaceable(p, walls: floorWalls, obstacles: obstacles) else { continue }
                        var testNodes = nodes
                        testNodes[nodeIndex] = p
                        let testSats = Array(testNodes.dropFirst())
                        if (!testSats.isEmpty || !requiredFixedIDs.isEmpty || lockedTargetInitiallyConnected)
                            && !isConnected(router: testNodes[0], satellites: testSats) {
                            continue
                        }
                        validProbes.append(p)
                    }
                    guard !validProbes.isEmpty else { break }

                    // Stage A: Screen all valid compass probes on coarsePointIndices with reflections: true
                    var probeCoarseLoss = [[Float]](repeating: [], count: validProbes.count)
                    probeCoarseLoss.withUnsafeMutableBufferPointer { buffer in
                        nonisolated(unsafe) let out = buffer
                        let pts = evalPoints
                        let cIndices = coarsePointIndices
                        let probes = validProbes
                        let refTx = router.txPower
                        DispatchQueue.concurrentPerform(iterations: probes.count) { idx in
                            if token?.isCancelled == true { return }
                            let origin = probes[idx]
                            var lossRow = [Float](repeating: 0, count: coarseCount)
                            for ci in 0..<coarseCount {
                                lossRow[ci] = model.effectiveLoss(
                                    from: origin, floorA: floor,
                                    to: pts[cIndices[ci]], floorB: floor,
                                    referenceTx: refTx, reflections: true
                                )
                            }
                            out[idx] = lossRow
                        }
                    }
                    if token?.isCancelled == true { return }

                    let rankedProbes = validProbes.indices
                        .map { idx in (idx, evaluateCoarseLossRow(probeCoarseLoss[idx], tx: tx, base: coarseBase).score) }
                        .sorted { $0.1 > $1.1 }
                    guard let topProbe = rankedProbes.first, topProbe.1 >= currentCoarseScore - 0.6 else { break }

                    // Stage B: Upgrade up to top 2 coarse probes to full pointCount rows, reusing coarsePointIndices
                    var accepted = false
                    for (pIdx, cScore) in rankedProbes.prefix(2) where cScore >= currentCoarseScore - 0.6 {
                        let p = validProbes[pIdx]
                        let cLoss = probeCoarseLoss[pIdx]
                        var pRow = [Float](repeating: 0, count: pointCount)
                        pRow.withUnsafeMutableBufferPointer { buffer in
                            nonisolated(unsafe) let outBuf = buffer
                            let pts = evalPoints
                            let lookup = coarseLookup
                            let refTx = router.txPower
                            DispatchQueue.concurrentPerform(iterations: pointCount) { pt in
                                if token?.isCancelled == true { return }
                                let ci = lookup[pt]
                                let loss = ci >= 0
                                    ? cLoss[ci]
                                    : model.effectiveLoss(from: p, floorA: floor, to: pts[pt], floorB: floor, referenceTx: refTx, reflections: true)
                                outBuf[pt] = tx - loss
                            }
                        }
                        if token?.isCancelled == true { return }

                        var testNodes = nodes
                        testNodes[nodeIndex] = p
                        let testSats = Array(testNodes.dropFirst())
                        let pen = backhaulPenalty(router: testNodes[0], satellites: testSats)
                        var combined = base
                        for pt in 0..<pointCount where pRow[pt] > combined[pt] { combined[pt] = pRow[pt] }
                        let fiveSafeguard = computeFiveSafeguard(router: testNodes[0], satellites: testSats)
                        let m = evaluateFull(combined, backhaulPenalty: pen, fiveSafeguard: fiveSafeguard)
                        if isBetter(m, than: bestMetrics) {
                            bestMetrics = m
                            bestPos = p
                            bestRow = pRow
                            currentCoarseLoss = cLoss
                            currentCoarseScore = cScore
                            nodes[nodeIndex] = p
                            rows[nodeIndex] = pRow
                            accepted = true
                            break
                        }
                    }
                    if !accepted { break }
                }
            }
        }

        // 4. Router-only (0 satellites) global + multi-basin compass search.
        let routerMovable = !request.lockRouter && router.floor == floor
        var routerPosition = router.position
        var routerRow = fullRow(at: routerPosition, tx: routerTx, sourceFloor: router.floor)
        let baselineConnected = (requiredFixedIDs.isEmpty && !lockedTargetInitiallyConnected) || isConnected(router: routerPosition, satellites: [])
        let baselineValid = baselineConnected
            && (router.floor != floor || (isInsideHome(routerPosition) && isPlaceable(routerPosition, walls: floorWalls, obstacles: obstacles)))
        let baselineMetrics = evaluateFull(
            combine([routerRow]),
            fiveSafeguard: computeFiveSafeguard(router: routerPosition, satellites: [])
        )

        var scoredUpgradedRouterCandidates: [(c: Int, metrics: EvalMetrics)] = []
        if routerMovable {
            for c in 0..<candidateCount where fullLossRows[c] != nil {
                let pos = candidates[c]
                if (!requiredFixedIDs.isEmpty || lockedTargetInitiallyConnected) && !isConnected(router: pos, satellites: []) { continue }
                let rRow = row(candidate: c, tx: routerTx)
                let m = evaluateFull(combine([rRow]), fiveSafeguard: computeFiveSafeguard(router: pos, satellites: []))
                scoredUpgradedRouterCandidates.append((c, m))
            }
            scoredUpgradedRouterCandidates.sort { $0.metrics > $1.metrics }

            // The candidate pool (apart from the current AP entries) does not depend on the router's current position,
            // so neither do these seeds; the current position is refined as one extra seed below.
            var seedPositions: [(pos: SIMD2<Float>, row: [Float])] = []
            for item in scoredUpgradedRouterCandidates {
                let p = candidates[item.c]
                if seedPositions.allSatisfy({ simd_distance($0.pos, p) >= routerSeedSpacing }) {
                    seedPositions.append((p, row(candidate: item.c, tx: routerTx)))
                    if seedPositions.count >= routerSeedCount { break }
                }
            }
            if baselineValid && seedPositions.allSatisfy({ simd_distance($0.pos, router.position) >= 0.35 }) {
                seedPositions.append((router.position, routerRow))
            } else if !baselineValid {
                let pushed = RoomPlanConverter.pushAwayFromWalls(router.position, walls: floorWalls, clearance: wallClearance + 0.01)
                if isInsideHome(pushed), isPlaceable(pushed, walls: floorWalls, obstacles: obstacles),
                   ((requiredFixedIDs.isEmpty && !lockedTargetInitiallyConnected) || isConnected(router: pushed, satellites: [])),
                   seedPositions.allSatisfy({ simd_distance($0.pos, pushed) >= 0.35 }) {
                    seedPositions.append((pushed, fullRow(at: pushed, tx: routerTx, sourceFloor: floor)))
                }
            }
            if seedPositions.isEmpty, let first = scoredUpgradedRouterCandidates.first {
                seedPositions.append((candidates[first.c], row(candidate: first.c, tx: routerTx)))
            }

            var bestSeedPos = routerPosition
            var bestSeedRow = routerRow
            var bestSeedMetrics = baselineValid ? baselineMetrics : EvalMetrics(coverage: -1, score: -1e9)

            for seed in seedPositions {
                if token?.isCancelled == true { return nil }
                var nodes = [seed.pos]
                var rows = [seed.row]
                compassRefineNode(nodeIndex: 0, nodes: &nodes, rows: &rows, steps: [0.25, 0.10, 0.05], maxIterationsPerStep: 2)
                let m = evaluateFull(combine(rows), fiveSafeguard: computeFiveSafeguard(router: nodes[0], satellites: []))
                if isBetter(m, than: bestSeedMetrics) {
                    bestSeedMetrics = m
                    bestSeedPos = nodes[0]
                    bestSeedRow = rows[0]
                }
            }

            if !baselineValid
                || bestSeedMetrics.coverage > baselineMetrics.coverage + 0.02
                || (bestSeedMetrics.coverage >= baselineMetrics.coverage - 1e-4 && bestSeedMetrics.score > baselineMetrics.score + 0.003) {
                routerPosition = bestSeedPos
                routerRow = bestSeedRow
            }
        }
        if token?.isCancelled == true { return nil }
        progress?(0.60)

        // 5. Satellites: Multi-start search + coordinate-descent refinement.
        struct ConfigRecord {
            var router: SIMD2<Float>
            var routerRow: [Float]
            var satellites: [SIMD2<Float>]
            var satelliteRows: [[Float]]
            var coverage: Float
            var targetCoverage: Float
            var score: Float
        }

        let best0Combined = combine([routerRow])
        let best0Metrics = evaluateFull(best0Combined, fiveSafeguard: computeFiveSafeguard(router: routerPosition, satellites: []))
        var configurations: [ConfigRecord] = [
            ConfigRecord(router: routerPosition, routerRow: routerRow, satellites: [], satelliteRows: [], coverage: best0Metrics.coverage, targetCoverage: best0Metrics.targetCoverage, score: best0Metrics.score)
        ]

        func greedyAddSatellite(
            router rPos: SIMD2<Float>,
            routerRow rRow: [Float],
            satellites sats: inout [SIMD2<Float>],
            satelliteRows sRows: inout [[Float]]
        ) -> Bool {
            let k = sats.count
            let tx = satelliteTx(k)
            if satelliteIsLocked(k) {
                let lockedPos = existingSatellites[k].position
                guard isInsideHome(lockedPos),
                      satelliteIsWired(k) || isConnected(router: rPos, satellites: sats + [lockedPos]) else {
                    return false
                }
                sats.append(lockedPos)
                sRows.append(fullRow(at: lockedPos, tx: tx))
                return true
            }
            let currentFull = combine([rRow] + sRows)
            let coarseBase = coarsePointIndices.map { currentFull[$0] }
            let wired = satelliteIsWired(k)
            var coarseRanking: [(c: Int, score: Float)] = []
            coarseRanking.reserveCapacity(candidateCount)
            for c in 0..<candidateCount {
                let cm = evaluateCoarseCandidate(c, tx: tx, base: coarseBase)
                coarseRanking.append((c, cm.score))
            }
            coarseRanking.sort { $0.score > $1.score }

            var topIndices: [Int] = []
            topIndices.reserveCapacity(4)
            for (c, _) in coarseRanking {
                if wired || isConnected(router: rPos, satellites: sats + [candidates[c]]) {
                    topIndices.append(c)
                    if topIndices.count >= 4 { break }
                }
            }
            guard !topIndices.isEmpty else { return false }
            ensureFullRows(for: topIndices)

            var bestC = topIndices[0]
            var bestMetrics = EvalMetrics(coverage: -1, score: -1e9)
            for c in topIndices {
                let pos = candidates[c]
                let testSats = sats + [pos]
                let candRow = row(candidate: c, tx: tx)
                var combined = currentFull
                for p in 0..<pointCount where candRow[p] > combined[p] { combined[p] = candRow[p] }
                let pen = backhaulPenalty(router: rPos, satellites: testSats)
                let m = evaluateFull(combined, backhaulPenalty: pen, fiveSafeguard: computeFiveSafeguard(router: rPos, satellites: testSats))
                if m > bestMetrics {
                    bestMetrics = m
                    bestC = c
                }
            }
            sats.append(candidates[bestC])
            sRows.append(row(candidate: bestC, tx: tx))
            return true
        }

        func refine(
            router: inout SIMD2<Float>,
            routerRow: inout [Float],
            routerMovable: Bool,
            satellites: inout [SIMD2<Float>],
            satelliteRows: inout [[Float]]
        ) {
            for _ in 0..<2 {
                if token?.isCancelled == true { return }
                let nodeCount = satellites.count + 1
                var anyChanged = false
                for node in 0..<nodeCount {
                    if node == 0 && !routerMovable { continue }
                    if node > 0 && satelliteIsLocked(node - 1) { continue }
                    let others: [[Float]] = node == 0
                        ? satelliteRows
                        : [routerRow] + satelliteRows.enumerated().filter { $0.offset != node - 1 }.map(\.element)
                    let base = combine(others)
                    let coarseBase = coarsePointIndices.map { base[$0] }
                    let currentRow = node == 0 ? routerRow : satelliteRows[node - 1]
                    let currentConnected = (satellites.isEmpty && requiredFixedIDs.isEmpty) || isConnected(router: router, satellites: satellites)
                    let tx = node == 0 ? routerTx : satelliteTx(node - 1)

                    var coarseTop: [(c: Int, score: Float)] = []
                    coarseTop.reserveCapacity(candidateCount)
                    for c in 0..<candidateCount {
                        let cm = evaluateCoarseCandidate(c, tx: tx, base: coarseBase)
                        coarseTop.append((c, cm.score))
                    }
                    coarseTop.sort { $0.score > $1.score }

                    var topIndices: [Int] = []
                    topIndices.reserveCapacity(4)
                    let needsConnCheck = !satellites.isEmpty || !requiredFixedIDs.isEmpty || lockedTargetInitiallyConnected
                    for (c, _) in coarseTop {
                        if needsConnCheck {
                            var testRouter = router
                            var testSats = satellites
                            if node == 0 { testRouter = candidates[c] } else { testSats[node - 1] = candidates[c] }
                            if !isConnected(router: testRouter, satellites: testSats) { continue }
                        }
                        topIndices.append(c)
                        if topIndices.count >= 4 { break }
                    }
                    guard !topIndices.isEmpty else { continue }
                    ensureFullRows(for: topIndices)
                    if token?.isCancelled == true { return }

                    var bestC = -1
                    var bestMetrics: EvalMetrics
                    if currentConnected {
                        let pen = backhaulPenalty(router: router, satellites: satellites)
                        bestMetrics = evaluateFull(
                            combine([base, currentRow]),
                            backhaulPenalty: pen,
                            fiveSafeguard: computeFiveSafeguard(router: router, satellites: satellites)
                        )
                    } else {
                        bestMetrics = EvalMetrics(coverage: -1, score: -1e9)
                    }

                    for c in topIndices {
                        let position = candidates[c]
                        var testRouter = router
                        var testSats = satellites
                        if node == 0 { testRouter = position } else { testSats[node - 1] = position }
                        let candRow = row(candidate: c, tx: tx)
                        var combined = base
                        for p in 0..<pointCount where candRow[p] > combined[p] { combined[p] = candRow[p] }
                        let pen = backhaulPenalty(router: testRouter, satellites: testSats)
                        let m = evaluateFull(
                            combined,
                            backhaulPenalty: pen,
                            fiveSafeguard: computeFiveSafeguard(router: testRouter, satellites: testSats)
                        )
                        if isBetter(m, than: bestMetrics) {
                            bestMetrics = m
                            bestC = c
                        }
                    }
                    guard bestC >= 0 else { continue }
                    let position = candidates[bestC]
                    if node == 0 {
                        router = position
                        routerRow = row(candidate: bestC, tx: tx)
                    } else {
                        satellites[node - 1] = position
                        satelliteRows[node - 1] = row(candidate: bestC, tx: tx)
                    }
                    anyChanged = true
                }
                if !anyChanged { break }
            }
        }

        if maxCount > 0 {
            var prevRouter = routerPosition
            var prevRouterRow = routerRow
            var prevSats: [SIMD2<Float>] = []
            var prevSatRows: [[Float]] = []

            for k in 0..<maxCount {
                if token?.isCancelled == true { return nil }
                let satCount = k + 1

                struct SeedConfig {
                    var router: SIMD2<Float>
                    var routerRow: [Float]
                    var satellites: [SIMD2<Float>]
                    var satelliteRows: [[Float]]
                }

                // Seed A: Greedy extension from best (satCount - 1) layout.
                var seedASats = prevSats
                var seedASatRows = prevSatRows
                guard greedyAddSatellite(router: prevRouter, routerRow: prevRouterRow, satellites: &seedASats, satelliteRows: &seedASatRows) else {
                    break
                }
                let greedyFallback = SeedConfig(router: prevRouter, routerRow: prevRouterRow, satellites: seedASats, satelliteRows: seedASatRows)
                var seeds: [SeedConfig] = [greedyFallback]

                // Seed B: Existing layout anchor.
                if !existingSatellites.isEmpty {
                    let bRouter = routerMovable ? router.position : prevRouter
                    let bRouterInside = router.floor != floor || isInsideHome(bRouter)
                    let prefixSats = Array(existingSatellites.prefix(satCount).map(\.position))
                    if bRouterInside && prefixSats.allSatisfy(isInsideHome) {
                        let bRouterRow = fullRow(at: bRouter, tx: routerTx, sourceFloor: router.floor)
                        var bSats = prefixSats
                        var bSatRows = prefixSats.enumerated().map { fullRow(at: $0.element, tx: satelliteTx($0.offset)) }
                        var ok = isConnected(router: bRouter, satellites: bSats)
                        while ok && bSats.count < satCount {
                            ok = greedyAddSatellite(router: bRouter, routerRow: bRouterRow, satellites: &bSats, satelliteRows: &bSatRows)
                        }
                        if ok && bSats.count == satCount && isConnected(router: bRouter, satellites: bSats) {
                            seeds.append(SeedConfig(router: bRouter, routerRow: bRouterRow, satellites: bSats, satelliteRows: bSatRows))
                        }
                    }
                }

                // Seed C: Spatially separated wing router + greedy satellites.
                if routerMovable,
                   let wingCand = scoredUpgradedRouterCandidates.first(where: { simd_distance(candidates[$0.c], prevRouter) >= 2.5 }) {
                    let cRouter = candidates[wingCand.c]
                    let cRouterRow = row(candidate: wingCand.c, tx: routerTx)
                    var cSats: [SIMD2<Float>] = []
                    var cSatRows: [[Float]] = []
                    var ok = true
                    for _ in 0..<satCount {
                        if !greedyAddSatellite(router: cRouter, routerRow: cRouterRow, satellites: &cSats, satelliteRows: &cSatRows) {
                            ok = false
                            break
                        }
                    }
                    if ok && cSats.count == satCount {
                        seeds.append(SeedConfig(router: cRouter, routerRow: cRouterRow, satellites: cSats, satelliteRows: cSatRows))
                    }
                }

                // Seed D: Weakest-room targeted satellite seed.
                if !satelliteIsLocked(k) && !rooms.isEmpty {
                    let prevCombined = combine([prevRouterRow] + prevSatRows)
                    var roomTotal = [Int](repeating: 0, count: rooms.count)
                    var roomCovered = [Int](repeating: 0, count: rooms.count)
                    for p in 0..<pointCount {
                        let rIdx = evalRoomIndices[p]
                        if rIdx >= 0 && rIdx < rooms.count {
                            roomTotal[rIdx] += 1
                            if prevCombined[p] >= threshold { roomCovered[rIdx] += 1 }
                        }
                    }
                    var weakestRoom = -1
                    var weakestFrac: Float = 2.0
                    for rIdx in rooms.indices where roomTotal[rIdx] > 0 {
                        let frac = Float(roomCovered[rIdx]) / Float(roomTotal[rIdx])
                        if frac < weakestFrac {
                            weakestFrac = frac
                            weakestRoom = rIdx
                        }
                    }
                    if weakestRoom >= 0 {
                        let coarseBase = coarsePointIndices.map { prevCombined[$0] }
                        let tx = satelliteTx(k)
                        var roomCands: [(c: Int, score: Float)] = []
                        for c in 0..<candidateCount where candidateRoomIndices[c] == weakestRoom {
                            let s = evaluateCoarseCandidate(c, tx: tx, base: coarseBase).score
                            roomCands.append((c, s))
                        }
                        roomCands.sort { $0.score > $1.score }
                        let wired = satelliteIsWired(k)
                        if let bestWeak = roomCands.first(where: { wired || isConnected(router: prevRouter, satellites: prevSats + [candidates[$0.c]]) }) {
                            let dSats = prevSats + [candidates[bestWeak.c]]
                            let dSatRows = prevSatRows + [row(candidate: bestWeak.c, tx: tx)]
                            seeds.append(SeedConfig(router: prevRouter, routerRow: prevRouterRow, satellites: dSats, satelliteRows: dSatRows))
                        }
                    }
                }

                var bestConfig = greedyFallback
                let fallbackPen = backhaulPenalty(router: greedyFallback.router, satellites: greedyFallback.satellites)
                var bestMetrics = evaluateFull(
                    combine([greedyFallback.routerRow] + greedyFallback.satelliteRows),
                    backhaulPenalty: fallbackPen,
                    fiveSafeguard: computeFiveSafeguard(router: greedyFallback.router, satellites: greedyFallback.satellites)
                )

                for var seed in seeds {
                    if token?.isCancelled == true { return nil }
                    refine(
                        router: &seed.router,
                        routerRow: &seed.routerRow,
                        routerMovable: routerMovable,
                        satellites: &seed.satellites,
                        satelliteRows: &seed.satelliteRows
                    )
                    let pen = backhaulPenalty(router: seed.router, satellites: seed.satellites)
                    let m = evaluateFull(
                        combine([seed.routerRow] + seed.satelliteRows),
                        backhaulPenalty: pen,
                        fiveSafeguard: computeFiveSafeguard(router: seed.router, satellites: seed.satellites)
                    )
                    if isBetter(m, than: bestMetrics) {
                        bestMetrics = m
                        bestConfig = seed
                    }
                }

                // If satCount matches existingSatellites.count, preserve existing positions unless strictly improved.
                if satCount == existingSatellites.count {
                    let exRouter = router.position
                    let exSats = existingSatellites.map(\.position)
                    let routerInside = router.floor != floor || (isInsideHome(exRouter) && isPlaceable(exRouter, walls: floorWalls, obstacles: obstacles))
                    if routerInside && exSats.allSatisfy({ isInsideHome($0) && isPlaceable($0, walls: floorWalls, obstacles: obstacles) })
                        && isConnected(router: exRouter, satellites: exSats) {
                        let exRouterRow = fullRow(at: exRouter, tx: routerTx, sourceFloor: router.floor)
                        let exSatRows = exSats.enumerated().map { fullRow(at: $0.element, tx: satelliteTx($0.offset)) }
                        let exPen = backhaulPenalty(router: exRouter, satellites: exSats)
                        let exMetrics = evaluateFull(
                            combine([exRouterRow] + exSatRows),
                            backhaulPenalty: exPen,
                            fiveSafeguard: computeFiveSafeguard(router: exRouter, satellites: exSats)
                        )
                        let strictlyBetter = bestMetrics.coverage > exMetrics.coverage + 0.02
                            || (bestMetrics.coverage >= exMetrics.coverage - (singleCellPct + 1e-3) && bestMetrics.score > exMetrics.score + 0.002)
                        if !strictlyBetter {
                            bestConfig = SeedConfig(router: exRouter, routerRow: exRouterRow, satellites: exSats, satelliteRows: exSatRows)
                            bestMetrics = exMetrics
                        }
                    }
                }

                // Monotonicity guard: adding a satellite never reduces coverage compared to (satCount - 1).
                if bestMetrics.coverage < configurations[k].coverage - 1e-4
                    || bestMetrics.targetCoverage < configurations[k].targetCoverage - 1e-4 {
                    bestConfig = greedyFallback
                    bestMetrics = evaluateFull(
                        combine([greedyFallback.routerRow] + greedyFallback.satelliteRows),
                        backhaulPenalty: fallbackPen,
                        fiveSafeguard: computeFiveSafeguard(router: greedyFallback.router, satellites: greedyFallback.satellites)
                    )
                }

                prevRouter = bestConfig.router
                prevRouterRow = bestConfig.routerRow
                prevSats = bestConfig.satellites
                prevSatRows = bestConfig.satelliteRows
                configurations.append(ConfigRecord(
                    router: bestConfig.router,
                    routerRow: bestConfig.routerRow,
                    satellites: bestConfig.satellites,
                    satelliteRows: bestConfig.satelliteRows,
                    coverage: bestMetrics.coverage,
                    targetCoverage: bestMetrics.targetCoverage,
                    score: bestMetrics.score
                ))
                progress?(0.60 + 0.35 * Double(k + 1) / Double(maxCount))
            }
        }

        // 6. Pick the satellite count and apply multi-scale compass refinement on the chosen layout.
        let chosenCount: Int
        switch request.satellites {
        case .exactly:
            chosenCount = configurations.count - 1
        case .automatic:
            var pick = configurations.count - 1
            for k in 0..<configurations.count {
                if configurations[k].coverage >= 90 { pick = k; break }
                if k + 1 < configurations.count && configurations[k + 1].coverage - configurations[k].coverage < 3 { pick = k; break }
            }
            chosenCount = pick
        }
        var chosen = configurations[chosenCount]
        if chosenCount > 0 {
            var nodes = [chosen.router] + chosen.satellites
            var rows = [chosen.routerRow] + chosen.satelliteRows
            for node in nodes.indices {
                if node == 0 && !routerMovable { continue }
                if node > 0 && satelliteIsLocked(node - 1) { continue }
                if token?.isCancelled == true { return nil }
                compassRefineNode(nodeIndex: node, nodes: &nodes, rows: &rows, steps: [0.18, 0.05], maxIterationsPerStep: 2)
            }
            let polishedPen = backhaulPenalty(router: nodes[0], satellites: Array(nodes.dropFirst()))
            let polishedMetrics = evaluateFull(
                combine(rows),
                backhaulPenalty: polishedPen,
                fiveSafeguard: computeFiveSafeguard(router: nodes[0], satellites: Array(nodes.dropFirst()))
            )
            if polishedMetrics.coverage >= chosen.coverage - 1e-4
                && polishedMetrics.targetCoverage >= chosen.targetCoverage - 1e-4 {
                chosen.router = nodes[0]
                chosen.satellites = Array(nodes.dropFirst())
                configurations[chosenCount].coverage = polishedMetrics.coverage
                configurations[chosenCount].targetCoverage = polishedMetrics.targetCoverage
                for m in (chosenCount + 1)..<configurations.count {
                    configurations[m].coverage = max(configurations[m].coverage, configurations[m - 1].coverage)
                    configurations[m].targetCoverage = max(configurations[m].targetCoverage, configurations[m - 1].targetCoverage)
                }
            }
        }
        progress?(1)

        return PlacementProposal(
            routerPosition: chosen.router,
            satellitePositions: chosen.satellites,
            recommendedSatelliteCount: chosenCount,
            estimatedCoverageBySatelliteCount: configurations.map(\.targetCoverage),
            executionTimeMs: (CFAbsoluteTimeGetCurrent() - start) * 1000
        )
    }

    /// A node can sit here: away from walls and outside furniture.
    public static func isPlaceable(_ p: SIMD2<Float>, walls: [RFWallSegment], obstacles: [[SIMD2<Float>]]) -> Bool {
        if obstacles.contains(where: { Geometry.contains($0, p) }) { return false }
        for w in walls where w.distance(to: p) < wallClearance { return false }
        return true
    }
}

/// Smooth coverage utility (logistic around the threshold), tabulated every 0.1 dB.
struct UtilityTable {
    let low: Float = -130
    let high: Float = -20
    let values: [Float]

    init(threshold: Float) {
        let count = Int((high - low) * 10) + 1
        values = (0..<count).map { i in
            let rssi = -130 + Float(i) * 0.1
            return 1 / (1 + exp(-(rssi - threshold) / 2.5))
        }
    }

    @inline(__always)
    func value(_ rssi: Float) -> Float {
        let index = Int((rssi - low) * 10)
        if index <= 0 { return values[0] }
        if index >= values.count { return values[values.count - 1] }
        return values[index]
    }
}
