import Foundation
import CoreGraphics
import simd
import os

/// Thread-safe cancellation flag readable from `concurrentPerform` workers.
public final class CancellationToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() { state.withLock { $0 = true } }
    public var isCancelled: Bool { state.withLock { $0 } }
}

public struct FieldGrid: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public let cell: Float

    public init(cols: Int, rows: Int, cell: Float) {
        self.cols = cols
        self.rows = rows
        self.cell = cell
    }

    /// Grid covering the plan with square cells close to `targetCell`, capped at `maxCells`.
    public static func covering(width: Float, depth: Float, targetCell: Float, maxCells: Int) -> FieldGrid {
        guard width.isFinite, depth.isFinite, width > 0, depth > 0, targetCell.isFinite else {
            return FieldGrid(cols: 1, rows: 1, cell: 1)
        }
        let limit = min(max(1, maxCells), 1_000_000)
        let w = Double(width), d = Double(depth)
        var cell = max(Double(max(targetCell, 0.001)), sqrt(w * d / Double(limit)), max(w, d) / Double(limit))
        var cols = max(1, Int(ceil(w / cell)))
        var rows = max(1, Int(ceil(d / cell)))
        while cols * rows > limit {
            cell *= 1.01
            cols = max(1, Int(ceil(w / cell)))
            rows = max(1, Int(ceil(d / cell)))
        }
        return FieldGrid(cols: cols, rows: rows, cell: Float(cell))
    }

    public var count: Int { cols * rows }

    @inline(__always)
    public func center(col: Int, row: Int) -> SIMD2<Float> {
        SIMD2<Float>((Float(col) + 0.5) * cell, (Float(row) + 0.5) * cell)
    }

    public func cellIndex(for point: SIMD2<Float>) -> Int? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x / cell < Float(cols), point.y / cell < Float(rows) else { return nil }
        let col = Int(point.x / cell)
        let row = Int(point.y / cell)
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }
        return row * cols + col
    }
}

/// Which grid cells are inside the home, and in which room.
public struct InteriorMask: Sendable {
    public let grid: FieldGrid
    /// Room index per cell (into the rooms used to build the mask), −1 outside.
    public let roomIndex: [Int16]
    /// False when there are no room polygons; then every cell counts as interior.
    public let hasRooms: Bool

    public init(grid: FieldGrid, polygons: [[SIMD2<Float>]]) {
        self.grid = grid
        let valid = polygons.contains { $0.count >= 3 }
        self.hasRooms = valid
        guard valid else {
            self.roomIndex = Array(repeating: 0, count: grid.count)
            return
        }
        var index = Array(repeating: Int16(-1), count: grid.count)
        for (roomNumber, polygon) in polygons.enumerated() where polygon.count >= 3 {
            for row in 0..<grid.rows {
                let z = (Float(row) + 0.5) * grid.cell
                var xs: [Float] = []
                var j = polygon.count - 1
                for i in 0..<polygon.count {
                    let a = polygon[i]
                    let b = polygon[j]
                    if (a.y > z) != (b.y > z) {
                        xs.append(a.x + (z - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                    j = i
                }
                guard xs.count >= 2 else { continue }
                xs.sort()
                var k = 0
                while k + 1 < xs.count {
                    let startCol = max(0, Int(ceil(xs[k] / grid.cell - 0.5)))
                    let endCol = min(grid.cols - 1, Int(floor(xs[k + 1] / grid.cell - 0.5)))
                    if startCol <= endCol {
                        for col in startCol...endCol where index[row * grid.cols + col] < 0 {
                            index[row * grid.cols + col] = Int16(roomNumber)
                        }
                    }
                    k += 2
                }
            }
        }
        self.roomIndex = index
    }

    @inline(__always)
    public func isInterior(_ cell: Int) -> Bool { roomIndex[cell] >= 0 }

    public func contains(_ point: SIMD2<Float>) -> Bool {
        guard let cell = grid.cellIndex(for: point) else { return false }
        return isInterior(cell)
    }
}

public struct CoverageSummary: Equatable, Sendable {
    public var coveredPercent: Float
    public var medianRSSI: Float
    public var p10RSSI: Float
    public var cellCount: Int

    public static let empty = CoverageSummary(coveredPercent: 0, medianRSSI: -200, p10RSSI: -200, cellCount: 0)
}

public struct RoomCoverage: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: RoomKind
    public let labelPoint: SIMD2<Float>
    public let summary: CoverageSummary
    public let grade: SignalGrade
    /// AP serving most of the room.
    public let servingAccessPointId: String?
}

/// Best-server RSSI sampled on a grid for one band and floor.
public struct SignalField: Sendable {
    public let grid: FieldGrid
    public let band: RFBand
    public let floor: Int
    public let rssi: [Float]
    /// Index into the AP array of the serving AP per cell, −1 when none.
    public let server: [Int8]
    public let mask: InteriorMask
    public let scale: SignalScale

    public var coverage: CoverageSummary {
        SignalField.summarize(rssi.indices.filter { mask.isInterior($0) }.map { rssi[$0] }, threshold: scale.coverageThreshold)
    }

    /// Nearest-cell RSSI, nil outside the grid.
    public func value(at point: SIMD2<Float>) -> Float? {
        grid.cellIndex(for: point).map { rssi[$0] }
    }

    static func summarize(_ values: [Float], threshold: Float) -> CoverageSummary {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        let covered = sorted.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
        return CoverageSummary(
            coveredPercent: Float(covered) / Float(sorted.count) * 100,
            medianRSSI: sorted[sorted.count / 2],
            p10RSSI: sorted[min(sorted.count - 1, sorted.count / 10)],
            cellCount: sorted.count
        )
    }

    public func roomCoverage(rooms: [RoomInfo], accessPoints: [RFAccessPoint]) -> [RoomCoverage] {
        rooms.enumerated().map { number, room in
            var values: [Float] = []
            var servers: [Int8: Int] = [:]
            for cell in 0..<grid.count where Int(mask.roomIndex[cell]) == number {
                values.append(rssi[cell])
                servers[server[cell], default: 0] += 1
            }
            let summary = SignalField.summarize(values, threshold: scale.coverageThreshold)
            let dominant = servers.max { $0.value < $1.value }?.key ?? -1
            return RoomCoverage(
                id: room.id,
                name: room.name,
                kind: room.kind,
                labelPoint: room.labelPoint,
                summary: summary,
                grade: scale.grade(for: summary.medianRSSI),
                servingAccessPointId: dominant >= 0 && Int(dominant) < accessPoints.count ? accessPoints[Int(dominant)].id : nil
            )
        }
    }
}

public enum SignalFieldGenerator {
    /// Computes the field in parallel. Returns nil when cancelled.
    public static func compute(
        model: PropagationModel,
        accessPoints: [RFAccessPoint],
        floor: Int,
        mask: InteriorMask,
        scale: SignalScale,
        reflections: Bool = true,
        token: CancellationToken? = nil
    ) -> SignalField? {
        let grid = mask.grid
        let aps = accessPoints
        var rssi = Array(repeating: Float(-200), count: grid.count)
        var server = Array(repeating: Int8(-1), count: grid.count)
        rssi.withUnsafeMutableBufferPointer { rssiBuffer in
            server.withUnsafeMutableBufferPointer { serverBuffer in
                nonisolated(unsafe) let rssiOut = rssiBuffer
                nonisolated(unsafe) let serverOut = serverBuffer
                DispatchQueue.concurrentPerform(iterations: grid.rows) { row in
                    if token?.isCancelled == true { return }
                    for col in 0..<grid.cols {
                        let cell = row * grid.cols + col
                        guard mask.isInterior(cell) else { continue }
                        let result = model.best(from: aps, to: grid.center(col: col, row: row), floor: floor, reflections: reflections)
                        rssiOut[cell] = result.rssi
                        serverOut[cell] = Int8(clamping: result.index ?? -1)
                    }
                }
            }
        }
        if token?.isCancelled == true { return nil }
        return SignalField(grid: grid, band: model.band, floor: floor, rssi: rssi, server: server, mask: mask, scale: scale)
    }
}

// MARK: - Rendering helpers

public enum HeatmapImage {
    /// RGBA image (one pixel per cell); cells outside the home are transparent.
    /// Radius in meters of the display smoothing (reflection wedges become gradients; walls still cut sharply).
    public static let smoothingRadius: Float = 0.6

    public static func make(from field: SignalField) -> CGImage? {
        let grid = field.grid
        let values = smoothed(field)
        var pixels = [UInt8](repeating: 0, count: grid.count * 4)
        for cell in 0..<grid.count where field.mask.isInterior(cell) {
            let color = field.scale.color(for: values[cell])
            pixels[cell * 4 + 0] = UInt8(max(0, min(255, color.r * 255)))
            pixels[cell * 4 + 1] = UInt8(max(0, min(255, color.g * 255)))
            pixels[cell * 4 + 2] = UInt8(max(0, min(255, color.b * 255)))
            pixels[cell * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: grid.cols,
            height: grid.rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: grid.cols * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Gaussian-weighted average restricted to cells of the same room.
    static func smoothed(_ field: SignalField) -> [Float] {
        let grid = field.grid
        let radius = max(1, min(7, Int((smoothingRadius / grid.cell).rounded())))
        let sigma = Float(radius) * 0.5
        var weights: [Float] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                weights.append(exp(-Float(dx * dx + dy * dy) / (2 * sigma * sigma)))
            }
        }
        let side = radius * 2 + 1
        var out = field.rssi
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let cell = row * grid.cols + col
                let room = field.mask.roomIndex[cell]
                guard room >= 0 else { continue }
                var sum: Float = 0
                var total: Float = 0
                for dy in -radius...radius {
                    let r = row + dy
                    guard r >= 0, r < grid.rows else { continue }
                    for dx in -radius...radius {
                        let c = col + dx
                        guard c >= 0, c < grid.cols else { continue }
                        let j = r * grid.cols + c
                        guard field.mask.roomIndex[j] == room else { continue }
                        let w = weights[(dy + radius) * side + dx + radius]
                        sum += field.rssi[j] * w
                        total += w
                    }
                }
                if total > 0 { out[cell] = sum / total }
            }
        }
        return out
    }
}

/// Iso-RSSI lines via marching squares over interior cells, as plan-space segments (x1, z1, x2, z2).
public enum ContourExtractor {
    public static func segments(in field: SignalField, level: Float) -> [SIMD4<Float>] {
        let grid = field.grid
        guard grid.cols >= 2, grid.rows >= 2 else { return [] }
        var result: [SIMD4<Float>] = []
        for row in 0..<(grid.rows - 1) {
            for col in 0..<(grid.cols - 1) {
                let i00 = row * grid.cols + col
                let i10 = i00 + 1
                let i01 = i00 + grid.cols
                let i11 = i01 + 1
                guard field.mask.isInterior(i00), field.mask.isInterior(i10), field.mask.isInterior(i01), field.mask.isInterior(i11) else { continue }
                let v00 = field.rssi[i00], v10 = field.rssi[i10], v01 = field.rssi[i01], v11 = field.rssi[i11]
                let p00 = grid.center(col: col, row: row)
                let p10 = grid.center(col: col + 1, row: row)
                let p01 = grid.center(col: col, row: row + 1)
                let p11 = grid.center(col: col + 1, row: row + 1)

                var points: [SIMD2<Float>] = []
                func edge(_ a: SIMD2<Float>, _ va: Float, _ b: SIMD2<Float>, _ vb: Float) {
                    if (va >= level) != (vb >= level) {
                        let t = (level - va) / (vb - va)
                        points.append(a + (b - a) * t)
                    }
                }
                edge(p00, v00, p10, v10)
                edge(p10, v10, p11, v11)
                edge(p11, v11, p01, v01)
                edge(p01, v01, p00, v00)
                if points.count == 2 {
                    result.append(SIMD4<Float>(points[0].x, points[0].y, points[1].x, points[1].y))
                } else if points.count == 4 {
                    result.append(SIMD4<Float>(points[0].x, points[0].y, points[1].x, points[1].y))
                    result.append(SIMD4<Float>(points[2].x, points[2].y, points[3].x, points[3].y))
                }
            }
        }
        return result
    }
}
