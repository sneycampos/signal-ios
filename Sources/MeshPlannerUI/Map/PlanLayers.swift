import SwiftUI
import MeshPlannerCore
import simd

/// Everything needed to draw the plan once.
struct PlanSnapshot {
    var printPalette = false
    var project: FloorplanProject
    var floor: Int
    var heatmap: CGImage?
    var heatmapOpacity: Double
    var coverageContours: [SIMD4<Float>]
    var scale: SignalScale
    var probe: ProbeReading?
    var backhaul: [String: BackhaulLink]
    var selectedWallId: String?
    var showFurniture: Bool
    var showRays: Bool
    var proposal: PlacementProposal?
    var drawNodes: Bool
    var drawGrid: Bool

    @MainActor
    init(model: FloorplanViewModel, project: FloorplanProject, drawNodes: Bool = false, drawGrid: Bool = true) {
        self.project = project
        self.floor = model.floor
        self.heatmap = model.heatmapImage
        self.heatmapOpacity = model.heatmapOpacity
        self.coverageContours = model.coverageContours
        self.scale = model.scale
        self.probe = model.probe
        self.backhaul = model.backhaul
        if case .wall(let id) = model.selection { selectedWallId = id } else { selectedWallId = nil }
        self.showFurniture = model.showFurniture
        self.showRays = model.showRays
        if case .ready(let comparison) = model.optimizer, !comparison.isAlreadyOptimal { proposal = comparison.proposal } else { proposal = nil }
        self.drawNodes = drawNodes
        self.drawGrid = drawGrid
    }

    /// Static preview (thumbnails, report) without selection or probe.
    init(project: FloorplanProject, heatmap: CGImage?, drawNodes: Bool = true) {
        self.project = project
        self.floor = 0
        self.heatmap = heatmap
        self.heatmapOpacity = 0.95
        self.coverageContours = []
        self.scale = SignalScale(profile: project.profile)
        self.probe = nil
        self.backhaul = [:]
        self.selectedWallId = nil
        self.showFurniture = false
        self.showRays = false
        self.proposal = nil
        self.drawNodes = drawNodes
        self.drawGrid = false
    }
}

/// Static plan drawing shared by the interactive map, the 3D view, thumbnails and the PDF report.
struct PlanLayers: View {
    let snapshot: PlanSnapshot
    let transform: PlanTransform

    var body: some View {
        Canvas { context, size in
            PlanPainter(snapshot: snapshot, transform: transform).draw(in: &context, size: size)
        }
        .accessibilityHidden(true)
    }
}

struct PlanPainter {
    let snapshot: PlanSnapshot
    let transform: PlanTransform

    private var project: FloorplanProject { snapshot.project }
    private var floor: Int { snapshot.floor }
    private var ink: Color { snapshot.printPalette ? .black : .white }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        if snapshot.drawGrid { drawDotGrid(&context, size: size) }
        let rooms = project.rooms(onFloor: floor)
        let planRect = CGRect(origin: transform.origin, size: CGSize(width: transform.length(project.width), height: transform.length(project.depth)))
        var interior = Path()
        for room in rooms { interior.addPath(transform.path(room.polygon)) }
        if rooms.isEmpty { interior = Path(roundedRect: planRect, cornerRadius: 6) }

        context.fill(interior, with: .color(ink.opacity(0.05)))
        if let heatmap = snapshot.heatmap, snapshot.heatmapOpacity > 0.02 {
            context.drawLayer { layer in
                layer.clip(to: interior)
                layer.opacity = snapshot.heatmapOpacity
                layer.draw(Image(decorative: heatmap, scale: 1).interpolation(.high), in: planRect)
            }
        }
        drawContours(&context)
        if snapshot.showFurniture { drawFurniture(&context) }
        drawWalls(&context)
        drawBackhaul(&context)
        if snapshot.showRays { drawRays(&context) }
        drawMeasurements(&context)
        drawProposal(&context)
        if snapshot.drawNodes { drawNodes(&context) }
    }

    private func drawDotGrid(_ context: inout GraphicsContext, size: CGSize) {
        let spacing = max(12, transform.length(0.5))
        let startX = transform.origin.x.truncatingRemainder(dividingBy: spacing)
        let startY = transform.origin.y.truncatingRemainder(dividingBy: spacing)
        var dots = Path()
        var x = startX
        while x < size.width {
            var y = startY
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(.white.opacity(0.07)))
    }

    private func drawContours(_ context: inout GraphicsContext) {
        guard snapshot.heatmap != nil, !snapshot.coverageContours.isEmpty else { return }
        var p = Path()
        for s in snapshot.coverageContours {
            p.move(to: transform.point(SIMD2(s.x, s.y)))
            p.addLine(to: transform.point(SIMD2(s.z, s.w)))
        }
        context.stroke(p, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 4]))
    }

    private func drawFurniture(_ context: inout GraphicsContext) {
        for item in project.furniture where item.floor == floor {
            let half = item.size * 0.5
            let corners = [SIMD2<Float>(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)].map {
                item.position + Geometry.rotate($0, by: item.yaw)
            }
            let shape = transform.path(corners)
            context.fill(shape, with: .color(ink.opacity(0.06)))
            context.stroke(shape, with: .color(ink.opacity(0.4)), lineWidth: 0.8)
        }
    }

    private func drawWalls(_ context: inout GraphicsContext) {
        for wall in project.walls where wall.floor == floor && wall.isActive {
            let a = transform.point(wall.p1)
            let b = transform.point(wall.p2)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            if wall.id == snapshot.selectedWallId {
                context.stroke(path, with: .color(.accentColor.opacity(0.55)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
            switch wall.kind {
            case .obstacle:
                context.stroke(path, with: .color(ink.opacity(0.6)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            case .opening:
                break
            case .door:
                drawDoor(&context, wall: wall, from: a, to: b)
            case .window:
                drawWindow(&context, from: a, to: b)
            case .wall:
                // Thinner on thumbnails so walls do not hide the heatmap.
                let zoomFactor = max(0.3, min(1, transform.scale / 20))
                let base: CGFloat = (wall.isExterior ? 3.2 : 2.2) * zoomFactor
                context.stroke(path, with: .color(snapshot.printPalette ? .black : Theme.wall), style: StrokeStyle(lineWidth: base, lineCap: .round))
            }
        }
    }

    private func drawWindow(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.001, hypot(dx, dy))
        let n = CGPoint(x: -dy / length * 1.6, y: dx / length * 1.6)
        for sign in [-1.0, 1.0] {
            var line = Path()
            line.move(to: CGPoint(x: a.x + n.x * sign, y: a.y + n.y * sign))
            line.addLine(to: CGPoint(x: b.x + n.x * sign, y: b.y + n.y * sign))
            context.stroke(line, with: .color(snapshot.printPalette ? .blue : Theme.window), style: StrokeStyle(lineWidth: 1.2, lineCap: .butt))
        }
    }

    /// Door leaf plus quarter swing arc drawn from the first jamb.
    private func drawDoor(_ context: inout GraphicsContext, wall: RFWallSegment, from a: CGPoint, to b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let radius = hypot(dx, dy)
        guard radius > 4 else { return }
        let start = atan2(dy, dx)
        let side = sideTowardRoom(wall)
        let end = start + side * .pi / 2
        let leafEnd = CGPoint(x: a.x + cos(end) * radius, y: a.y + sin(end) * radius)
        var leaf = Path()
        leaf.move(to: a)
        leaf.addLine(to: leafEnd)
        context.stroke(leaf, with: .color(ink.opacity(0.7)), lineWidth: 1.2)
        var arc = Path()
        arc.addArc(center: a, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: side < 0)
        context.stroke(arc, with: .color(ink.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
    }

    /// +1 or −1: the side of the wall (in screen space) that lies inside a room.
    private func sideTowardRoom(_ wall: RFWallSegment) -> CGFloat {
        let probe = wall.midpoint + wall.normal * 0.4
        return project.rooms(onFloor: floor).contains { $0.contains(probe) } ? 1 : -1
    }

    private func drawBackhaul(_ context: inout GraphicsContext) {
        for ap in project.accessPoints where ap.floor == floor && ap.isSatellite {
            guard let link = snapshot.backhaul[ap.id], let parent = project.accessPoints.first(where: { $0.id == link.parentId }) else { continue }
            let a = transform.point(parent.position)
            let b = transform.point(ap.position)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let color = snapshot.printPalette ? Color.black : link.quality.color
            context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: link.quality == .wired ? [1, 5] : [3, 5]))
            guard let rssi = link.rssi else { continue }
            // Middle of the link, pushed sideways so it does not sit on the line or the nodes.
            let length = max(1, hypot(b.x - a.x, b.y - a.y))
            let side = CGPoint(x: -(b.y - a.y) / length * 16, y: (b.x - a.x) / length * 16)
            let mid = CGPoint(x: (a.x + b.x) / 2 + (side.y > 0 ? -side.x : side.x), y: (a.y + b.y) / 2 - abs(side.y))
            let resolved = context.resolve(Text(Format.dbm(rssi)).font(.caption2.weight(.semibold)).foregroundStyle(color))
            let size = resolved.measure(in: CGSize(width: 200, height: 40))
            let box = CGRect(x: mid.x - size.width / 2 - 6, y: mid.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(snapshot.printPalette ? .white : .black.opacity(0.75)))
            context.stroke(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(color.opacity(0.5)), lineWidth: 0.8)
            context.draw(resolved, at: mid)
        }
    }

    private func drawRays(_ context: inout GraphicsContext) {
        guard let probe = snapshot.probe, probe.floor == floor, let budget = probe.budget, budget.accessPoint.floor == floor else { return }
        let apPoint = transform.point(budget.accessPoint.position)
        let probePoint = transform.point(probe.point)
        for reflection in budget.reflections.prefix(3) {
            var path = Path()
            path.move(to: apPoint)
            path.addLine(to: transform.point(reflection.reflPoint))
            path.addLine(to: probePoint)
            context.stroke(path, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        var direct = Path()
        direct.move(to: apPoint)
        direct.addLine(to: probePoint)
        context.stroke(direct, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
        for crossing in budget.crossings {
            let c = transform.point(crossing.point)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.orange))
            context.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawMeasurements(_ context: inout GraphicsContext) {
        for m in project.measurements where m.floor == floor {
            let c = transform.point(m.position)
            var diamond = Path()
            diamond.move(to: CGPoint(x: c.x, y: c.y - 6))
            diamond.addLine(to: CGPoint(x: c.x + 6, y: c.y))
            diamond.addLine(to: CGPoint(x: c.x, y: c.y + 6))
            diamond.addLine(to: CGPoint(x: c.x - 6, y: c.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(.purple))
            context.draw(Text(Format.dbm(m.rssi)).font(.caption2.bold()).foregroundStyle(.purple), at: CGPoint(x: c.x, y: c.y - 14))
        }
    }

    private func drawProposal(_ context: inout GraphicsContext) {
        guard let proposal = snapshot.proposal else { return }
        let targets = [proposal.routerPosition] + proposal.satellitePositions
        let current = project.accessPoints.filter { $0.floor == floor }
        let router = current.first { !$0.isSatellite }
        let satellites = current.filter(\.isSatellite).sorted { ($0.backhaul == .wired ? 0 : 1) < ($1.backhaul == .wired ? 0 : 1) }
        for (i, target) in targets.enumerated() {
            if i == 0 && router == nil { continue }
            let t = transform.point(target)
            let from: SIMD2<Float>? = i == 0 ? router?.position : (i - 1 < satellites.count ? satellites[i - 1].position : nil)
            if let from, simd_distance(from, target) > 0.2 {
                var arrow = Path()
                arrow.move(to: transform.point(from))
                arrow.addLine(to: t)
                context.stroke(arrow, with: .color(.accentColor.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            let ring = Path(ellipseIn: CGRect(x: t.x - 20, y: t.y - 20, width: 40, height: 40))
            context.fill(ring, with: .color(.accentColor.opacity(0.2)))
            context.stroke(ring, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            var symbol = context.resolve(Image(systemName: i == 0 ? "wifi.router" : "dot.radiowaves.left.and.right"))
            symbol.shading = .color(.white)
            context.draw(symbol, at: t)
        }
    }

    private func drawNodes(_ context: inout GraphicsContext) {
        for ap in project.accessPoints where ap.floor == floor {
            let c = transform.point(ap.position)
            let radius: CGFloat = 13
            context.fill(Path(ellipseIn: CGRect(x: c.x - radius - 6, y: c.y - radius - 6, width: (radius + 6) * 2, height: (radius + 6) * 2)), with: .color((ap.isSatellite ? Color.green : Color.cyan).opacity(0.25)))
            context.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white))
            if snapshot.printPalette {
                context.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)), with: .color(.black), lineWidth: 1)
            }
            var symbol = context.resolve(Image(systemName: ap.isSatellite ? "dot.radiowaves.left.and.right" : "wifi.router"))
            symbol.shading = .color(snapshot.printPalette ? .black : (ap.isSatellite ? .green : .blue))
            context.draw(symbol, at: c)
        }
    }
}
