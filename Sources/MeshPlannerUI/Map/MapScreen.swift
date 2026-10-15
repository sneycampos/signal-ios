import SwiftUI
import MeshPlannerCore

/// The project screen: full-bleed plan with floating header, band picker, control rail and summary card.
struct MapScreen: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var viewport = PlanViewport()
    /// Global Y where the floating header ends and where the summary card starts.
    @State private var topChrome: CGFloat = 170
    @State private var cardTop: CGFloat = 560
    @State private var railBottom: CGFloat = 330
    @State private var showInspector = false
    @State private var sheetDetent: PresentationDetent = .medium
    @State private var showEquipment = false
    @State private var showOptimizer = false
    @State private var showCalibration = false
    @State private var showAR = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var reportURL: URL?
    @State private var diagnostics: String?

    var body: some View {
        if let project = model.project {
            content(project)
        }
    }

    @ViewBuilder
    private func content(_ project: FloorplanProject) -> some View {
        GeometryReader { geometry in
        ZStack {
            switch model.viewMode {
            case .plan:
                FloorplanCanvas(project: project, viewport: $viewport, freeTop: topChrome + 8, freeBottom: cardTop - 8, railBottom: railBottom) { showInspector = true }
            case .perspective:
                PerspectivePlan(project: project, freeTop: topChrome, freeBottom: cardTop)
            }

            VStack(spacing: 10) {
                VStack(spacing: 10) {
                    header(project)
                    BandPicker(bands: project.profile.supportedBands, selection: model.band) { model.setBand($0) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topChrome = $0 }
                banners
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .top)

            controlRail(project)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { railBottom = $0 }
                .padding(.trailing, 16)
                .padding(.top, topChrome + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            ScrollView {
                SummaryCard(onAddSatellite: {
                model.addSatellite()
                showInspector = true
            }, onOptimize: {
                showOptimizer = true
            }, onSelectRoom: { id in
                model.selection = .room(id)
                showInspector = true
                })
            }
            .frame(maxHeight: geometry.size.height * 0.48)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardTop = $0 }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        }
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onChange(of: showInspector) { if showInspector { sheetDetent = .medium } }
        .onChange(of: showOptimizer) { if showOptimizer { sheetDetent = .medium } }
        .onChange(of: showCalibration) { if showCalibration { sheetDetent = .medium } }
        .onChange(of: project.id) {
            viewport = PlanViewport()
            showInspector = false
            showEquipment = false
            showOptimizer = false
            showCalibration = false
            showAR = false
            showRename = false
            reportURL = nil
            diagnostics = nil
        }
        .onChange(of: model.optimizer) { _, state in
            // Lower the sheet so the proposed positions are visible on the map.
            if case .ready = state, showOptimizer { withAnimation(reduceMotion ? nil : .default) { sheetDetent = .fraction(0.3) } }
        }
        .sheet(isPresented: $showInspector) {
            InspectorSheet()
                .presentationDetents([.fraction(0.3), .medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showEquipment) { EquipmentSheet() }
        .sheet(isPresented: $showOptimizer) {
            OptimizerSheet()
                .presentationDetents([.fraction(0.3), .medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationSheet()
                .presentationDetents([.fraction(0.3), .medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(item: Binding(get: { reportURL.map(ReportFile.init) }, set: { reportURL = $0?.url })) { file in
            ReportShareSheet(url: file.url)
        }
        .sheet(item: Binding(get: { diagnostics.map(DiagnosticsText.init) }, set: { diagnostics = $0?.text })) { item in
            DiagnosticsSheet(text: item.text)
        }
        .fullScreenCover(isPresented: $showAR) { ARWalkthroughView() }
        .alert("Rename project", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(to: renameText) }
        }
        #if DEBUG
        .task { await debugAutomation() }
        #endif
        .task(id: model.shouldPresentSetup) {
            guard model.shouldPresentSetup else { return }
            try? await Task.sleep(for: .milliseconds(700))
            model.shouldPresentSetup = false
            showEquipment = true
        }
    }

    // MARK: Header

    private func header(_ project: FloorplanProject) -> some View {
        HStack(spacing: 12) {
            CircleIconButton(systemImage: "chevron.left", label: "Back to projects") { Task { await model.close() } }
                .accessibilityIdentifier("backToProjects")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(project))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            moreMenu(project)
        }
    }

    private func subtitle(_ project: FloorplanProject) -> String {
        let rooms = project.rooms.count
        let area = Format.area(project.areaM2)
        let floor = project.floorCount > 1 ? " · \(floorName(model.floor))" : ""
        return String(localized: "\(rooms) rooms · \(area)") + floor
    }

    private func floorName(_ floor: Int) -> String {
        floor == 0 ? String(localized: "Ground floor") : String(localized: "Floor \(floor)")
    }

    private func moreMenu(_ project: FloorplanProject) -> some View {
        Menu {
            Section {
                Button { showEquipment = true } label: { Label("Equipment and preferences", systemImage: "wifi.router") }
                Button { model.tool = .placeRouter } label: { Label("Place the router", systemImage: "hand.tap") }
                Menu("Place router in a room") {
                    ForEach(project.rooms(onFloor: model.floor)) { room in
                        Button(room.name) {
                            model.tool = .placeRouter
                            model.handleTap(at: room.labelPoint, wallTolerance: 0)
                            if let router = model.project?.router { model.selection = .accessPoint(router.id); showInspector = true }
                        }
                    }
                }
                Menu("Edit walls and objects") {
                    ForEach(project.walls.filter { $0.floor == model.floor }) { wall in
                        Button("\(wall.name) · \(wall.material.name)") {
                            model.selection = .wall(wall.id)
                            showInspector = true
                        }
                    }
                }
                Button { showCalibration = true } label: { Label("Calibrate with measurements", systemImage: "scope") }
                Button { showAR = true } label: { Label("View in augmented reality", systemImage: "arkit") }
                    .disabled(!model.hasWorldMap || project.worldAlignment == nil || model.isComputing || model.heatmapImage == nil)
            }
            Section {
                ShareLink(item: ProjectDocument(project: project), preview: SharePreview(project.name)) {
                    Label("Share project", systemImage: "square.and.arrow.up")
                }
                Button {
                    reportURL = ReportRenderer.render(model: model, project: project)
                } label: {
                    Label("PDF report", systemImage: "doc.richtext")
                }
                .disabled(model.isComputing || model.field == nil)
                if !project.isDemo {
                    Button {
                        renameText = project.name
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
            }
            Menu {
                if let data = model.webExportData() {
                    ShareLink(item: WebFloorplanDocument(data: data, name: project.name), preview: SharePreview(project.name)) {
                        Label("Export to the web simulator", systemImage: "globe")
                    }
                }
                Button { diagnostics = model.diagnosticsText() } label: { Label("Diagnostics", systemImage: "stethoscope") }
            } label: {
                Label("Advanced", systemImage: "gearshape.2")
            }
            SupportLinks()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(Circle())
        .accessibilityLabel("More options")
    }

    // MARK: Control rail

    private func controlRail(_ project: FloorplanProject) -> some View {
        VStack(spacing: 10) {
            CircleIconButton(systemImage: model.viewMode == .plan ? "cube" : "square.grid.2x2", label: model.viewMode == .plan ? "View in 3D" : "View in 2D") {
                let next: MapViewMode = model.viewMode == .plan ? .perspective : .plan
                if reduceMotion { model.viewMode = next } else { withAnimation(.smooth) { model.viewMode = next } }
            }
            CircleIconButton(systemImage: "scope", label: "Center plan") {
                withAnimation(reduceMotion ? nil : .snappy) { viewport = PlanViewport() }
            }
            .opacity(viewport.isDefault ? 0.6 : 1)
            layersMenu(project)
                .accessibilityIdentifier("mapLayers")
            if model.canUndo {
                CircleIconButton(systemImage: "arrow.uturn.backward", label: "Undo") { model.undo() }
                    .accessibilityIdentifier("undo")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.canUndo)
    }

    private func layersMenu(_ project: FloorplanProject) -> some View {
        Menu {
            if project.floorCount > 1 {
                Picker("Floor", selection: Binding(get: { model.floor }, set: { model.setFloor($0) })) {
                    ForEach(0..<project.floorCount, id: \.self) { Text(floorName($0)).tag($0) }
                }
            }
            Toggle(isOn: Binding(get: { model.showRays }, set: { model.showRays = $0 })) {
                Label("Signal path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Toggle(isOn: Binding(get: { model.showFurniture }, set: { model.showFurniture = $0 })) {
                Label("Show furniture", systemImage: "sofa")
            }
            Picker("Map opacity", selection: Binding(get: { model.heatmapOpacity }, set: { model.heatmapOpacity = $0 })) {
                Text("Strong map").tag(0.9)
                Text("Soft map").tag(0.55)
                Text("Plan only").tag(0.0)
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(Circle())
        .accessibilityLabel("Map layers")
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        switch model.tool {
        case .placeRouter:
            Banner(icon: "hand.tap", text: "Tap the plan where your router is.") { model.tool = .normal }
        case .addMeasurement:
            Banner(icon: "scope", text: "Tap the spot where you took the measurement.") { model.tool = .normal }
        case .normal:
            EmptyView()
        }
        if let toast = model.toast {
            ToastView(toast: toast)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
        }
    }

    #if DEBUG
    private func debugAutomation() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openSheet"), i + 1 < args.count else { return }
        try? await Task.sleep(for: .milliseconds(600))
        switch args[i + 1] {
        case "inspector": showInspector = true
        case "equipment": showEquipment = true
        case "calibration": showCalibration = true
        case "optimizer":
            showOptimizer = true
            model.runOptimizer(satellites: .automatic, lockRouter: false)
        case "perspective": model.viewMode = .perspective
        default: break
        }
    }
    #endif
}

// MARK: - Band picker

struct BandPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bands: [RFBand]
    let selection: RFBand
    var onSelect: (RFBand) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(bands) { band in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { onSelect(band) }
                } label: {
                    Text(band.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(band == selection ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if band == selection {
                                Capsule().fill(.white).matchedGeometryEffect(id: "band", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(band == selection ? .isSelected : [])
                .accessibilityIdentifier("band-\(band.rawValue)")
            }
        }
        .padding(4)
        .glassSurface(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wi-Fi band")
        .accessibilityIdentifier("bandToggle")
    }
}

// MARK: - Summary card

struct SummaryCard: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onAddSatellite: () -> Void
    var onOptimize: () -> Void
    var onSelectRoom: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.percent(model.coverage.coveredPercent))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("of your home has good signal")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 4)
                ZStack {
                    CoverageVerdict(percent: model.coverage.coveredPercent)
                        .opacity(model.isComputing ? 0 : 1)
                    if model.isComputing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            SignalLegend(scale: model.scale)

            if !rooms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(rooms) { room in
                            Button { onSelectRoom(room.id) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(model.scale.uiColor(for: room.grade)).frame(width: 8, height: 8)
                                    Text(room.name).foregroundStyle(.white)
                                    Text(Format.percent(room.summary.coveredPercent)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(room.name): \(Format.percent(room.summary.coveredPercent)) with good signal"))
                        }
                    }
                }
                .scrollClipDisabled()
            }

            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                Button(action: onAddSatellite) {
                    Label("Satellite", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 18)
                        .frame(minHeight: 50)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add mesh satellite")
                .accessibilityIdentifier("addSatellite")

                Button(action: onOptimize) {
                    Label("Optimize placement", systemImage: "sparkles")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("optimize")
            }
        }
        .padding(18)
        .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// Rooms that need attention first.
    private var rooms: [RoomCoverage] {
        model.roomCoverage.filter { $0.summary.cellCount > 0 }.sorted { $0.summary.coveredPercent < $1.summary.coveredPercent }
    }
}

struct CoverageVerdict: View {
    let percent: Float

    var body: some View {
        let (title, color): (LocalizedStringKey, Color) = switch percent {
        case 90...: ("Great", .green)
        case 75..<90: ("Good", .mint)
        case 50..<75: ("Fair", .yellow)
        default: ("Weak", .orange)
        }
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }
}

private struct ReportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct DiagnosticsText: Identifiable {
    let text: String
    var id: Int { text.hashValue }
}

struct Banner: View {
    let icon: String
    let text: LocalizedStringKey
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Cancel")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ToastView: View {
    @Environment(FloorplanViewModel.self) private var model
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline).foregroundStyle(.white)
            Spacer(minLength: 4)
            if toast.offersUndo {
                Button("Undo") { model.undo() }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Read-only tilted view of the plan.
struct PerspectivePlan: View {
    @Environment(FloorplanViewModel.self) private var model
    let project: FloorplanProject
    var freeTop: CGFloat
    var freeBottom: CGFloat

    var body: some View {
        GeometryReader { geo in
            let usable = CGSize(width: geo.size.width - 64, height: max(1, freeBottom - freeTop))
            let transform: PlanTransform = {
                var t = PlanTransform.fitting(width: project.width, depth: project.depth, in: usable, zoom: 0.95, pan: .zero)
                t.origin.x += 8
                t.origin.y += freeTop
                return t
            }()
            ZStack {
                Theme.canvas
                PlanLayers(snapshot: PlanSnapshot(model: model, project: project, drawNodes: true, drawGrid: false), transform: transform)
                    .rotation3DEffect(.degrees(40), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("3D view of the plan. To edit, go back to 2D.")
    }
}
