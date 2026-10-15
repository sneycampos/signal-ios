import CoreGraphics
import Foundation
import Testing
@testable import MeshPlannerCore

@Suite("Room label layout")
struct RoomLabelLayoutTests {
    /// Mirrors the canvas: plan meters -> screen points, fixed label sizes.
    static func inputs(_ coverage: [RoomCoverage], rooms: [RoomInfo], scale: CGFloat = 40, origin: CGPoint = CGPoint(x: 20, y: 120)) -> [RoomLabelInput] {
        let areas = Dictionary(rooms.map { ($0.id, $0.area) }, uniquingKeysWith: { a, _ in a })
        return coverage.filter { areas[$0.id] != nil }.map {
            RoomLabelInput(id: $0.id,
                           anchor: CGPoint(x: origin.x + CGFloat($0.labelPoint.x) * scale, y: origin.y + CGFloat($0.labelPoint.y) * scale),
                           area: areas[$0.id] ?? 0,
                           fullSize: CGSize(width: CGFloat($0.name.count) * 7 + 12, height: 34),
                           compactSize: CGSize(width: 40, height: 18))
        }
    }

    static func crowded() -> [RoomLabelInput] {
        (0..<12).map { i in
            RoomLabelInput(id: "r\(i)", anchor: CGPoint(x: 100 + CGFloat(i % 3) * 30, y: 100 + CGFloat(i / 3) * 20),
                           area: Float(i % 4), fullSize: CGSize(width: 70, height: 34), compactSize: CGSize(width: 40, height: 18))
        }
    }

    @Test func placedLabelsNeverOverlap() {
        let inputs = Self.crowded()
        let placed = RoomLabelLayout.layout(inputs)
        let frames = placed.compactMap { $0.frame(in: inputs) }
        #expect(frames.count == placed.count)
        #expect(!placed.isEmpty)
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]), "\(placed[i].id) overlaps \(placed[j].id)")
            }
        }
    }

    @Test func layoutIsDeterministicAndOrderIndependent() {
        let inputs = Self.crowded()
        let reference = RoomLabelLayout.layout(inputs)
        for seed in 0..<20 {
            var rng = SeededGenerator(seed: UInt64(seed + 1))
            #expect(RoomLabelLayout.layout(inputs.shuffled(using: &rng)) == reference)
        }
    }

    @Test func panningMovesEveryLabelRigidly() {
        let inputs = Self.crowded()
        let shifted = inputs.map { var i = $0; i.anchor.x += 37; i.anchor.y -= 11; return i }
        let a = RoomLabelLayout.layout(inputs)
        let b = RoomLabelLayout.layout(shifted)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.map(\.compact) == b.map(\.compact))
        for (p, q) in zip(a, b) {
            #expect(abs(q.center.x - p.center.x - 37) < 0.001 && abs(q.center.y - p.center.y + 11) < 0.001)
        }
    }

    /// The reported bug: dragging the probe (or a router) reshuffled the room labels.
    @Test @MainActor func labelsDoNotMoveWhenTheProbeOrARouterIsDragged() async throws {
        let model = FloorplanViewModel(store: ProjectStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await model.openDemo()
        try await settle(model)
        let project = try #require(model.project)
        let rooms = project.rooms(onFloor: model.floor)
        let reference = RoomLabelLayout.layout(Self.inputs(model.roomCoverage, rooms: rooms))
        #expect(reference.count >= 2)

        for room in rooms {
            for offset in [SIMD2<Float>(0, 0), SIMD2(0.3, -0.4), SIMD2(-0.5, 0.2)] {
                model.placeProbe(at: room.labelPoint + offset)
                #expect(RoomLabelLayout.layout(Self.inputs(model.roomCoverage, rooms: rooms)) == reference)
            }
        }

        let ap = try #require(project.accessPoints.first)
        model.beginDrag(accessPointId: ap.id)
        for step in 0..<5 {
            model.moveAccessPoint(id: ap.id, to: ap.position + SIMD2(Float(step) * 0.4, 0.2))
            #expect(RoomLabelLayout.layout(Self.inputs(model.roomCoverage, rooms: rooms)) == reference)
        }
        model.endDrag()
        try await settle(model)
        #expect(RoomLabelLayout.layout(Self.inputs(model.roomCoverage, rooms: rooms)) == reference)
        await model.close()
    }

    @MainActor private func settle(_ model: FloorplanViewModel) async throws {
        for _ in 0..<400 where model.isComputing || model.roomCoverage.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.roomCoverage.isEmpty)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
