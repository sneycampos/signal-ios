import SwiftUI
import SignalCore
import simd

/// Zoom and pan of the plan, owned by the map screen so the recenter button can reset it.
struct PlanViewport: Equatable {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var isDefault: Bool { zoom == 1 && pan == .zero }
}

/// Interactive 2D plan: pan, pinch-zoom anchored at the fingers, tap to inspect, drag routers and the probe.
struct FloorplanCanvas: View {
    @Environment(FloorplanViewModel.self) private var model
    let project: FloorplanProject
    @Binding var viewport: PlanViewport
    /// Global Y range left free by the floating header and summary card; the plan fits inside it.
    var freeTop: CGFloat
    var freeBottom: CGFloat
    /// Global Y where the right-hand control rail ends.
    var railBottom: CGFloat
    var onOpenInspector: () -> Void

    @GestureState private var livePan: CGSize = .zero
    @GestureState private var liveMagnify: (scale: CGFloat, anchor: CGPoint)? = nil

    var body: some View {
        GeometryReader { geo in
            let transform = currentTransform(size: geo.size)
            ZStack {
                Theme.canvas
                PlanLayers(snapshot: PlanSnapshot(model: model, project: project), transform: transform)
                    .contentShape(Rectangle())
                    .gesture(tapGesture(transform))
                    .gesture(panGesture)
                    .simultaneousGesture(magnifyGesture(size: geo.size))

                ForEach(layoutLabels(transform)) { item in
                    RoomLabel(coverage: item.coverage, compact: item.compact) {
                        model.selection = .room(item.coverage.id)
                        onOpenInspector()
                    }
                    .position(item.center)
                }

                if let probe = model.probe, probe.floor == model.floor {
                    ProbePin(reading: probe, transform: transform, onOpenInspector: onOpenInspector)
                }

                ForEach(project.accessPoints.filter { $0.floor == model.floor }) { ap in
                    AccessPointNode(ap: ap, transform: transform, onOpenInspector: onOpenInspector)
                }

                #if DEBUG
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("heatmap")
                    .accessibilityLabel("Signal heatmap")
                    .accessibilityValue("generation=\(model.heatmapPublishCount),live=\(model.liveHeatmapPublishCount)")
                #endif
            }
            .coordinateSpace(.named(PlanSpace.name))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Coverage map")
            .accessibilityValue(Text("\(Format.percent(model.coverage.coveredPercent)) of your home has good signal"))
        }
        .ignoresSafeArea()
    }

    /// Fits the plan in the free band between header and card, left of the control rail so no node hides under it.
    private func fitting(size: CGSize, zoom: CGFloat, pan: CGSize) -> PlanTransform {
        let top = max(0, min(freeTop, size.height - 100))
        let bottom = max(top + 100, min(freeBottom, size.height))
        let usable = CGSize(width: max(1, size.width - 8 - 64), height: bottom - top)
        var t = PlanTransform.fitting(width: project.width, depth: project.depth, in: usable, zoom: zoom, pan: pan, inset: 10)
        t.origin.x += 8
        t.origin.y += top
        return t
    }

    private func currentTransform(size: CGSize) -> PlanTransform {
        let base = fitting(size: size, zoom: viewport.zoom, pan: CGSize(width: viewport.pan.width + livePan.width, height: viewport.pan.height + livePan.height))
        guard let magnify = liveMagnify else { return base }
        return zoomed(base, by: magnify.scale, around: magnify.anchor)
    }

    private func zoomed(_ t: PlanTransform, by factor: CGFloat, around anchor: CGPoint) -> PlanTransform {
        let clamped = max(0.7 / viewport.zoom, min(6 / viewport.zoom, factor))
        return PlanTransform(
            scale: t.scale * clamped,
            origin: CGPoint(x: anchor.x - (anchor.x - t.origin.x) * clamped, y: anchor.y - (anchor.y - t.origin.y) * clamped)
        )
    }

    private func tapGesture(_ transform: PlanTransform) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(PlanSpace.name)).onEnded { value in
            model.handleTap(at: transform.plan(value.location), wallTolerance: transform.meters(14))
            if case .wall = model.selection { onOpenInspector() }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($livePan) { value, state, _ in state = value.translation }
            .onEnded { value in
                viewport.pan.width += value.translation.width
                viewport.pan.height += value.translation.height
            }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($liveMagnify) { value, state, _ in state = (value.magnification, value.startLocation) }
            .onEnded { value in
                let base = fitting(size: size, zoom: viewport.zoom, pan: viewport.pan)
                let result = zoomed(base, by: value.magnification, around: value.startLocation)
                let newZoom = max(0.7, min(6, viewport.zoom * value.magnification))
                let centered = fitting(size: size, zoom: newZoom, pan: .zero)
                viewport = PlanViewport(zoom: newZoom, pan: CGSize(width: result.origin.x - centered.origin.x, height: result.origin.y - centered.origin.y))
            }
    }

    // MARK: Room labels

    private struct LabelLayout: Identifiable {
        let coverage: RoomCoverage
        let center: CGPoint
        let compact: Bool
        var id: String { coverage.id }
    }

    /// Room labels depend only on room geometry and the map transform, never on the probe or the
    /// routers, so dragging them cannot reshuffle the labels (they draw above the labels instead).
    private func layoutLabels(_ transform: PlanTransform) -> [LabelLayout] {
        let rooms = project.rooms(onFloor: model.floor)
        let areas = Dictionary(rooms.map { ($0.id, $0.area) }, uniquingKeysWith: { first, _ in first })
        let labels = model.roomCoverage.filter { areas[$0.id] != nil && $0.summary.cellCount > 0 }
        let byId = Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Sized for the widest percentage so a changing value never changes the layout.
        let percentSize = ("100%" as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption2)])
        let inputs = labels.map { label in
            let nameSize = (label.name as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)])
            return RoomLabelInput(
                id: label.id,
                anchor: transform.point(label.labelPoint),
                area: areas[label.id] ?? 0,
                fullSize: CGSize(width: max(nameSize.width, percentSize.width) + 12, height: nameSize.height + percentSize.height + 8),
                compactSize: CGSize(width: percentSize.width + 8, height: percentSize.height + 4)
            )
        }
        return RoomLabelLayout.layout(inputs).compactMap { placed in
            byId[placed.id].map { LabelLayout(coverage: $0, center: placed.center, compact: placed.compact) }
        }
    }
}

enum PlanSpace {
    static let name = "plan"
}

// MARK: - Room label

struct RoomLabel: View {
    let coverage: RoomCoverage
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                if !compact {
                    Text(coverage.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                ZStack {
                    Text("100%").hidden()
                    Text(Format.percent(coverage.summary.coveredPercent))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.caption2.weight(.medium).monospacedDigit())
            }
            .shadow(color: .black.opacity(0.9), radius: 3)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text("\(coverage.name): \(Format.percent(coverage.summary.coveredPercent)) with good signal"))
        .accessibilityIdentifier("roomLabel-\(coverage.name)")
    }
}

// MARK: - Access point node

struct AccessPointNode: View {
    @Environment(FloorplanViewModel.self) private var model
    let ap: RFAccessPoint
    let transform: PlanTransform
    var onOpenInspector: () -> Void

    @GestureState private var isDragging = false
    @State private var grabOffset: CGSize = .zero

    var body: some View {
        let selected = model.selection == .accessPoint(ap.id)
        let glow: Color = ap.isSatellite ? .green : .cyan
        ZStack {
            Circle()
                .fill(glow.opacity(isDragging ? 0.4 : 0.22))
                .frame(width: isDragging ? 66 : 52, height: isDragging ? 66 : 52)
                .blur(radius: 6)
            Circle()
                .fill(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
                .shadow(color: glow.opacity(0.7), radius: isDragging ? 14 : 8)
            Image(systemName: ap.isSatellite ? "dot.radiowaves.left.and.right" : "wifi.router")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(ap.isSatellite ? .green : .blue)
            if ap.isLocked && !ap.isSatellite {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.7), in: Circle())
                    .offset(x: 15, y: -15)
            }
            if isDragging {
                Text("\(Format.percent(model.coverage.coveredPercent)) with good signal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75), in: Capsule())
                    .offset(y: -50)
                    .fixedSize()
            }
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .gesture(dragGesture)
        .onTapGesture {
            model.selection = .accessPoint(ap.id)
            onOpenInspector()
        }
        .onChange(of: isDragging) { wasDragging, dragging in
            if wasDragging && !dragging { model.endDrag() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isDragging) { _, new in new }
        .position(transform.point(ap.position))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ap.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(ap.isSatellite ? "satellite" : "router")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selection = .accessPoint(ap.id); onOpenInspector() }
        .accessibilityAction(named: "Move up") { model.nudgeAccessPoint(id: ap.id, by: SIMD2(0, -0.5)) }
        .accessibilityAction(named: "Move down") { model.nudgeAccessPoint(id: ap.id, by: SIMD2(0, 0.5)) }
        .accessibilityAction(named: "Move left") { model.nudgeAccessPoint(id: ap.id, by: SIMD2(-0.5, 0)) }
        .accessibilityAction(named: "Move right") { model.nudgeAccessPoint(id: ap.id, by: SIMD2(0.5, 0)) }
    }

    private var accessibilityValue: Text {
        let room = model.project?.room(containing: ap.position, floor: ap.floor)?.name ?? ""
        if ap.isSatellite, let link = model.backhaul[ap.id] {
            return Text("\(room). Link to router: \(link.rssi.map { Format.dbm($0) } ?? String(localized: "cable"))")
        }
        return Text(room)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(PlanSpace.name))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if model.draggingAccessPointId != ap.id {
                    let center = transform.point(ap.position)
                    grabOffset = CGSize(width: center.x - value.startLocation.x, height: center.y - value.startLocation.y)
                    model.beginDrag(accessPointId: ap.id)
                    model.selection = .accessPoint(ap.id)
                }
                let target = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                model.moveAccessPoint(id: ap.id, to: transform.plan(target))
            }
    }
}

// MARK: - Probe

struct ProbePin: View {
    @Environment(FloorplanViewModel.self) private var model
    let reading: ProbeReading
    let transform: PlanTransform
    var onOpenInspector: () -> Void

    @State private var grabOffset: CGSize = .zero
    @State private var dragStarted = false
    @GestureState private var isDragging = false

    var body: some View {
        let point = transform.point(reading.point)
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(Format.dbm(reading.rssi)).font(.caption.weight(.bold).monospacedDigit())
                Text("·").foregroundStyle(.white.opacity(0.5))
                Text(Format.mbps(reading.effectiveThroughputMbps)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay(Capsule().stroke(Color.yellow.opacity(0.8), lineWidth: 1))
            .fixedSize()

            Image(systemName: "mappin")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.6), radius: 3)
        }
        .frame(width: 130, height: 66, alignment: .bottom)
        .contentShape(Rectangle())
        // The pin tip sits at the bottom of the frame.
        .position(x: point.x, y: point.y - 33)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(PlanSpace.name))
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { value in
                    if !dragStarted {
                        dragStarted = true
                        grabOffset = CGSize(width: point.x - value.startLocation.x, height: point.y - value.startLocation.y)
                    }
                    model.placeProbe(at: transform.plan(CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)))
                }
        )
        .onChange(of: isDragging) { _, dragging in
            if !dragging { dragStarted = false }
        }
        .onTapGesture {
            model.selection = nil
            onOpenInspector()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("probe")
        .accessibilityLabel("Measurement point")
        .accessibilityValue(Text("\(reading.roomName ?? ""), \(Format.dbm(reading.rssi)), \(Format.mbps(reading.effectiveThroughputMbps))"))
        .accessibilityHint("Double-tap to see details")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenInspector() }
        .accessibilityAction(named: "Move up") { model.placeProbe(at: reading.point + SIMD2(0, -0.5)) }
        .accessibilityAction(named: "Move down") { model.placeProbe(at: reading.point + SIMD2(0, 0.5)) }
        .accessibilityAction(named: "Move left") { model.placeProbe(at: reading.point + SIMD2(-0.5, 0)) }
        .accessibilityAction(named: "Move right") { model.placeProbe(at: reading.point + SIMD2(0.5, 0)) }
    }
}
