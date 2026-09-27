import Foundation
import Testing
import simd
@testable import SignalCore

/// Uses a real project captured on an iPhone 16 Pro (legacy geometry: doors overlapping walls, 3 broken room loops).
@Suite("Real scan repair")
struct RealScanTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/real-scan.signalsim")

    func loadRepaired() throws -> FloorplanProject {
        let data = try Data(contentsOf: Self.fixture)
        let project = try ProjectStore.decoder().decode(FloorplanProject.self, from: data)
        #expect(project.schemaVersion < FloorplanProject.currentSchemaVersion)
        return ProjectRepair.upgradeIfNeeded(project)
    }

    @Test func everyEnclosedRegionBecomesARoom() throws {
        let project = try loadRepaired()
        for room in project.rooms {
            print("room", room.name, String(format: "%.1f m²", room.area), room.polygon.count, "pts")
        }
        #expect(project.rooms.count >= 6)
        let area = project.rooms.reduce(0) { $0 + $1.area }
        #expect(area > 50 && area < 110)
    }

    @Test func noWallOverlapsAnOpeningAfterRepair() throws {
        let project = try loadRepaired()
        let openings = project.walls.filter { $0.kind == .opening || $0.kind == .door }
        let model = PropagationModel(walls: project.walls, band: .five)
        for o in openings {
            let n = o.normal * 0.4
            let loss = model.wallLoss(o.midpoint.x - n.x, o.midpoint.y - n.y, o.midpoint.x + n.x, o.midpoint.y + n.y, floor: 0)
            #expect(loss < 1, "doorway \(o.name) still blocked by \(loss) dB")
        }
    }

    @Test func heatmapFillsEveryRoom() throws {
        let project = try loadRepaired()
        let model = PropagationModel(walls: project.walls, band: .five)
        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.1, maxCells: 30_000)
        let mask = InteriorMask(grid: grid, polygons: project.rooms.map(\.polygon))
        let field = try #require(SignalFieldGenerator.compute(model: model, accessPoints: project.accessPoints, floor: 0, mask: mask, scale: .default))
        for room in field.roomCoverage(rooms: project.rooms, accessPoints: project.accessPoints) {
            print(room.name, Format.percentText(room.summary.coveredPercent), room.summary.medianRSSI)
            #expect(room.summary.cellCount > 0, "\(room.name) has no heatmap cells")
        }
        let values = (0..<grid.count).filter { mask.isInterior($0) }.map { field.rssi[$0] }
        let spread = (values.max() ?? 0) - (values.min() ?? 0)
        #expect(spread > 15, "heatmap should vary across the home")
    }

    @Test func interiorPartitionsAreNotBrick() throws {
        let project = try loadRepaired()
        let interior = project.walls.filter { $0.kind == .wall && !$0.isExterior }
        let exterior = project.walls.filter { $0.kind == .wall && $0.isExterior }
        print("interior", interior.count, "exterior", exterior.count)
        #expect(interior.allSatisfy { $0.material.id != RFMaterial.brick.id })
        #expect(!exterior.isEmpty)
    }
}

private enum Format {
    static func percentText(_ v: Float) -> String { String(format: "%.0f%%", v) }
}
