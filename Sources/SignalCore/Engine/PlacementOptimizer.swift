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
        maxSatellites: Int = 3
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
    }
}

public struct PlacementProposal: Equatable, Sendable {
    public let routerPosition: SIMD2<Float>
    public let satellitePositions: [SIMD2<Float>]
    public let recommendedSatelliteCount: Int
    /// Quick estimate of covered area for 0…N satellites (direct path, percent).
    public let estimatedCoverageBySatelliteCount: [Float]
    public let executionTimeMs: Double
}

/// Places the router and mesh satellites to maximize weighted coverage inside the home, keeping every
/// wireless satellite within backhaul reach (≥ −70 dBm) of the router or another satellite.
public enum PlacementOptimizer {
    public static let minimumBackhaulRSSI: Float = -70
    static let wallClearance: Float = 0.25
    static let maxPoints = 1400

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
        let model = PropagationModel(walls: request.walls, band: profile.planningBand, calibration: request.calibration, floorHeight: profile.floorHeight)
        let backhaulModel = PropagationModel(walls: request.walls, band: profile.effectiveBackhaulBand, calibration: request.calibration, floorHeight: profile.floorHeight)

        // 1. Evaluation points inside the home, weighted by room importance.
        let rooms = request.rooms.filter { $0.floor == floor && $0.polygon.count >= 3 }
        guard rooms.count <= maxPoints else { return nil }
        let area = max(1, rooms.isEmpty ? request.width * request.depth : rooms.reduce(0) { $0 + $1.area })
        let step = max(0.5, (area / Float(maxPoints)).squareRoot())
        let grid = FieldGrid.covering(width: request.width, depth: request.depth, targetCell: step, maxCells: maxPoints)
        let obstacles = Geometry.obstacleFootprints(request.walls, floor: floor)
        let floorWalls = request.walls.filter { $0.floor == floor && $0.isActive && !$0.material.isTransparent }

        var points: [SIMD2<Float>] = []
        var weights: [Float] = []
        var candidateIndices: [Int] = []
        func append(_ p: SIMD2<Float>, weight: Float) {
            guard points.count < maxPoints, !obstacles.contains(where: { Geometry.contains($0, p) }) else { return }
            weights.append(weight)
            if isPlaceable(p, walls: floorWalls, obstacles: obstacles) { candidateIndices.append(points.count) }
            points.append(p)
        }
        if rooms.isEmpty {
            for row in 0..<grid.rows {
                for col in 0..<grid.cols { append(grid.center(col: col, row: row), weight: 1) }
            }
        } else {
            // Budget each room separately, so empty space between rooms cannot consume all samples.
            let remaining = maxPoints - rooms.count
            let totalArea = max(0.001, rooms.reduce(0) { $0 + $1.area })
            for room in rooms {
                guard token?.isCancelled != true else { return nil }
                append(room.labelPoint, weight: room.kind.importance)
                let budget = Int(Float(remaining) * room.area / totalArea)
                guard budget > 0 else { continue }
                let (lo, hi) = Geometry.bounds(room.polygon)
                let local = FieldGrid.covering(width: hi.x - lo.x, depth: hi.y - lo.y, targetCell: step, maxCells: budget)
                for row in 0..<local.rows {
                    for col in 0..<local.cols {
                        let p = lo + local.center(col: col, row: row)
                        if room.contains(p) { append(p, weight: room.kind.importance) }
                    }
                }
            }
        }
        guard !points.isEmpty, !candidateIndices.isEmpty else { return nil }
        let totalWeight = weights.reduce(0, +)
        let utility = UtilityTable(threshold: threshold)

        // 2. Loss from every candidate to every point (the expensive part, done once).
        let pointCount = points.count
        let candidateCount = candidateIndices.count
        let allocation = candidateCount.multipliedReportingOverflow(by: pointCount)
        guard !allocation.overflow, allocation.partialValue <= maxPoints * maxPoints else { return nil }
        var loss = [Float](repeating: 0, count: allocation.partialValue)
        loss.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            let pts = points
            let cands = candidateIndices
            DispatchQueue.concurrentPerform(iterations: candidateCount) { c in
                if token?.isCancelled == true { return }
                let origin = pts[cands[c]]
                for p in 0..<pointCount {
                    out[c * pointCount + p] = model.pathLoss(from: origin, floorA: floor, to: pts[p], floorB: floor)
                }
            }
        }
        if token?.isCancelled == true { return nil }
        progress?(0.35)

        let maxCount: Int
        switch request.satellites {
        case .automatic: maxCount = max(0, min(request.maxSatellites, 6))
        case .exactly(let n): maxCount = max(0, min(n, 6))
        }

        let routerTx = router.txPower + request.calibration.offsetDb
        let existingSatellites = request.accessPoints
            .filter { $0.isSatellite && $0.floor == floor }
            .sorted { ($0.backhaul == .wired ? 0 : 1) < ($1.backhaul == .wired ? 0 : 1) }
        let fixedAPs = request.accessPoints.filter { $0.isSatellite && $0.floor != floor && $0.isActive }
        let fixedRows = fixedAPs.map { ap in points.map { model.rssi(from: ap, to: $0, floor: floor) } }
        func satelliteTx(_ i: Int) -> Float { (i < existingSatellites.count ? existingSatellites[i].txPower : 20.0) + request.calibration.offsetDb }
        func satelliteIsWired(_ i: Int) -> Bool { i < existingSatellites.count && existingSatellites[i].backhaul == .wired }

        func row(candidate c: Int, tx: Float) -> [Float] {
            (0..<pointCount).map { tx - loss[c * pointCount + $0] }
        }
        func directRow(at position: SIMD2<Float>, tx: Float, sourceFloor: Int? = nil) -> [Float] {
            points.map { tx - model.pathLoss(from: position, floorA: sourceFloor ?? floor, to: $0, floorB: floor) }
        }
        func score(_ best: [Float]) -> Float {
            var total: Float = 0
            for p in 0..<pointCount { total += weights[p] * utility.value(best[p]) }
            return total / totalWeight
        }
        func coverage(_ best: [Float]) -> Float {
            Float(best.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }) / Float(pointCount) * 100
        }
        func combine(_ rows: [[Float]]) -> [Float] {
            var best = [Float](repeating: -200, count: pointCount)
            for r in rows + fixedRows { for p in 0..<pointCount where r[p] > best[p] { best[p] = r[p] } }
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
                // Rebuild connectivity from the proposal, never from satellites it replaces.
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
        /// Every wireless satellite must reach the router through a chain of links ≥ −70 dBm.
        func isConnected(router r: SIMD2<Float>, satellites: [SIMD2<Float>]) -> Bool {
            let result = evaluateConnectivity(router: r, satellites: satellites)
            return result.remaining.isEmpty && !result.unreachedFixed.contains { requiredFixedIDs.contains($0.id) }
        }

        // 3. Router position.
        let routerMovable = !request.lockRouter && router.floor == floor
        var routerPosition = router.position
        var routerRow: [Float]
        if !routerMovable {
            routerRow = directRow(at: routerPosition, tx: routerTx, sourceFloor: router.floor)
        } else {
            var bestC = -1
            var bestScore: Float = -1
            for c in 0..<candidateCount {
                let position = points[candidateIndices[c]]
                if !requiredFixedIDs.isEmpty && !isConnected(router: position, satellites: []) { continue }
                let s = score(row(candidate: c, tx: routerTx))
                if s > bestScore { bestScore = s; bestC = c }
            }
            if bestC >= 0 {
                routerPosition = points[candidateIndices[bestC]]
                routerRow = row(candidate: bestC, tx: routerTx)
            } else {
                routerRow = directRow(at: routerPosition, tx: routerTx, sourceFloor: router.floor)
            }
        }
        if token?.isCancelled == true { return nil }
        progress?(0.45)

        // 4. Satellites: greedy growth then coordinate-descent refinement, for each count considered.
        var configurations: [(router: SIMD2<Float>, satellites: [SIMD2<Float>], coverage: Float, score: Float)] = []
        var satellites: [SIMD2<Float>] = []
        var satelliteRows: [[Float]] = []
        configurations.append((routerPosition, [], coverage(combine([routerRow])), score(combine([routerRow]))))

        if maxCount > 0 {
            for k in 0..<maxCount {
                if token?.isCancelled == true { return nil }
                let current = combine([routerRow] + satelliteRows)
                let tx = satelliteTx(k)
                var bestC = -1
                var bestScore: Float = -1
                for c in 0..<candidateCount {
                    let position = points[candidateIndices[c]]
                    if !satelliteIsWired(k) {
                        let reachable = isConnected(router: routerPosition, satellites: satellites + [position])
                        if !reachable { continue }
                    }
                    var total: Float = 0
                    for p in 0..<pointCount {
                        total += weights[p] * utility.value(max(current[p], tx - loss[c * pointCount + p]))
                    }
                    let s = total / totalWeight
                    if s > bestScore { bestScore = s; bestC = c }
                }
                guard bestC >= 0 else { break }
                satellites.append(points[candidateIndices[bestC]])
                satelliteRows.append(row(candidate: bestC, tx: tx))

                refine(
                    router: &routerPosition, routerRow: &routerRow, routerMovable: routerMovable,
                    satellites: &satellites, satelliteRows: &satelliteRows
                )
                let best = combine([routerRow] + satelliteRows)
                configurations.append((routerPosition, satellites, coverage(best), score(best)))
                progress?(0.45 + 0.5 * Double(k + 1) / Double(maxCount))
            }
        }

        func refine(router: inout SIMD2<Float>, routerRow: inout [Float], routerMovable: Bool, satellites: inout [SIMD2<Float>], satelliteRows: inout [[Float]]) {
            for _ in 0..<2 {
                let nodeCount = satellites.count + 1
                for node in 0..<nodeCount {
                    if node == 0 && !routerMovable { continue }
                    let others: [[Float]] = node == 0 ? satelliteRows : [routerRow] + satelliteRows.enumerated().filter { $0.offset != node - 1 }.map(\.element)
                    let base = combine(others)
                    let tx = node == 0 ? routerTx : satelliteTx(node - 1)
                    var bestC = -1
                    var bestScore: Float = -1
                    for c in 0..<candidateCount {
                        let position = points[candidateIndices[c]]
                        var testRouter = router
                        var testSats = satellites
                        if node == 0 { testRouter = position } else { testSats[node - 1] = position }
                        if (!testSats.isEmpty || !requiredFixedIDs.isEmpty) && !isConnected(router: testRouter, satellites: testSats) { continue }
                        var total: Float = 0
                        for p in 0..<pointCount {
                            total += weights[p] * utility.value(max(base[p], tx - loss[c * pointCount + p]))
                        }
                        let s = total / totalWeight
                        if s > bestScore { bestScore = s; bestC = c }
                    }
                    guard bestC >= 0 else { continue }
                    let position = points[candidateIndices[bestC]]
                    if node == 0 {
                        router = position
                        routerRow = row(candidate: bestC, tx: tx)
                    } else {
                        satellites[node - 1] = position
                        satelliteRows[node - 1] = row(candidate: bestC, tx: tx)
                    }
                }
            }
        }

        // 5. Pick the configuration.
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

        // 6. Fine local search (±0.3 m) around each node with fresh rows.
        let movable = routerMovable
        var nodes = [chosen.router] + chosen.satellites
        var rows = [directRow(at: chosen.router, tx: routerTx, sourceFloor: router.floor)] + chosen.satellites.enumerated().map { directRow(at: $0.element, tx: satelliteTx($0.offset)) }
        for node in nodes.indices {
            if node == 0 && !movable { continue }
            if token?.isCancelled == true { return nil }
            let base = combine(rows.enumerated().filter { $0.offset != node }.map(\.element))
            let tx = node == 0 ? routerTx : satelliteTx(node - 1)
            var bestPosition = nodes[node]
            var bestRow = rows[node]
            var bestScore = score(combine([base, bestRow]))
            for i in -3...3 {
                for j in -3...3 where i != 0 || j != 0 {
                    let p = nodes[node] + SIMD2<Float>(Float(i), Float(j)) * 0.1
                    let inside = rooms.isEmpty ? (p.x >= 0 && p.y >= 0 && p.x <= request.width && p.y <= request.depth) : rooms.contains { $0.contains(p) }
                    guard inside, isPlaceable(p, walls: floorWalls, obstacles: obstacles) else { continue }
                    var test = nodes
                    test[node] = p
                    if (test.count > 1 || !requiredFixedIDs.isEmpty) && !isConnected(router: test[0], satellites: Array(test.dropFirst())) { continue }
                    let candidateRow = directRow(at: p, tx: tx)
                    let s = score(combine([base, candidateRow]))
                    if s > bestScore { bestScore = s; bestPosition = p; bestRow = candidateRow }
                }
            }
            nodes[node] = bestPosition
            rows[node] = bestRow
        }
        chosen.router = nodes[0]
        chosen.satellites = Array(nodes.dropFirst())
        progress?(1)

        return PlacementProposal(
            routerPosition: chosen.router,
            satellitePositions: chosen.satellites,
            recommendedSatelliteCount: chosenCount,
            estimatedCoverageBySatelliteCount: configurations.map(\.coverage),
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
