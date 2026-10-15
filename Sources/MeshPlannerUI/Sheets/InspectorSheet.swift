import SwiftUI
import MeshPlannerCore
import simd

struct InspectorSheet: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.selection == nil, let probe = model.probe {
                    ProbeInspector(reading: probe) { dismiss() }
                } else {
                    List {
                        switch model.selection {
                        case .wall(let id):
                            if let wall = model.wall(id: id) { WallEditor(wall: wall) }
                        case .accessPoint(let id):
                            if let ap = model.accessPoint(id: id) { AccessPointEditor(ap: ap).id(ap.id) }
                        case .room(let id):
                            if let room = model.room(id: id) { RoomDetail(room: room).id(room.id) }
                        case nil:
                            EmptyView()
                        }
                        RoomsSection()
                    }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Point") { model.selection = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { dismiss() }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var title: LocalizedStringKey {
        switch model.selection {
        case .wall: return "Wall"
        case .accessPoint(let id): return model.accessPoint(id: id)?.isSatellite == true ? "Satellite" : "Router"
        case .room: return "Room"
        case nil: return "Signal at this point"
        }
    }
}

// MARK: - Probe

private struct ProbeInspector: View {
    @Environment(FloorplanViewModel.self) private var model
    let reading: ProbeReading
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.roomName ?? String(localized: "Outside rooms"))
                            .font(.title2.bold())
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close", action: onClose)
                }

                ZStack(alignment: .bottom) {
                    SignalGauge(rssi: reading.rssi, scale: model.scale)
                        .frame(height: 150)
                    VStack(spacing: 6) {
                        (Text("\(Int(reading.rssi.rounded()).formatted())").font(.system(size: 44, weight: .bold, design: .rounded)) + Text(" dBm").font(.title3.weight(.semibold)))
                            .monospacedDigit()
                        GradePill(grade: reading.grade, scale: model.scale)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Signal \(Format.dbm(reading.rssi))") + Text(", ") + Text(reading.grade.title))

                HStack(spacing: 10) {
                    MetricTile(title: "Wi-Fi", value: Format.mbps(reading.effectiveThroughputMbps))
                    MetricTile(title: "Internet", value: reading.internetMbps.map { Format.mbps($0) } ?? "—")
                    MetricTile(title: "Link", value: reading.servingAccessPoint?.name ?? "—")
                }

                Label {
                    Text(reading.grade.usage)
                } icon: {
                    Image(systemName: reading.grade.isCovered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(model.scale.uiColor(for: reading.grade))
                }
                .font(.subheadline)

                if let link = reading.backhaul, link.throughputMbps < reading.link.throughputMbps {
                    Label {
                        Text("Limited by the satellite’s link to the router (\(Format.mbps(link.throughputMbps))).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }

                if let budget = reading.budget {
                    NavigationLink {
                        BudgetDetail(reading: reading, budget: budget)
                    } label: {
                        HStack {
                            Text("How we calculate").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .cardSurface(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }

                Text("Model estimate. Drag the yellow pin on the map to measure another spot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var subtitle: String {
        guard let budget = reading.budget else { return model.band.displayName }
        return String(localized: "\(Format.meters(budget.distanceMeters)) from \(budget.accessPoint.name) · \(model.band.displayName)")
    }
}

private struct MetricTile: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .padding(.horizontal, 6)
        .cardSurface(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }
}

private struct BudgetDetail: View {
    let reading: ProbeReading
    let budget: LinkBudget

    var body: some View {
        List {
            Section {
                BudgetRow(title: "Power of \(budget.accessPoint.name)", value: "+" + Format.dbm(budget.txPowerDbm))
                BudgetRow(title: "Device margin (antenna, hand)", value: "−" + Format.decibels(budget.deviceMarginDb))
                BudgetRow(title: "Distance (\(Format.meters(budget.distanceMeters)))", value: "−" + Format.decibels(budget.freeSpaceLossDb))
                ForEach(Array(budget.crossings.enumerated()), id: \.offset) { _, crossing in
                    BudgetRow(title: "\(crossing.wall.name) · \(crossing.wall.material.name)", value: "−" + Format.decibels(crossing.loss), indent: true)
                }
                if budget.floorLossDb > 0 {
                    BudgetRow(title: "Floor slab between stories", value: "−" + Format.decibels(budget.floorLossDb))
                }
                BudgetRow(title: "Direct path", value: Format.dbm(budget.directRssiDbm))
                if budget.reflectionGainDb > 0.05 {
                    BudgetRow(title: "Reflections (\(budget.reflections.count))", value: "+" + Format.decibels(budget.reflectionGainDb))
                }
                BudgetRow(title: "Final signal", value: Format.dbm(budget.finalRssiDbm), bold: true)
            } header: {
                Text("Signal calculation")
            }
            Section {
                LabeledContent("SNR", value: Format.decibels(reading.link.snr))
                LabeledContent("Link rate (PHY)", value: Format.mbps(reading.link.phyRateMbps))
                if let mcs = reading.link.mcs { LabeledContent("MCS", value: mcs.formatted()) }
            } footer: {
                Text("Multi-wall model: free-space loss + each wall (higher at an angle) + first-order reflections, with 3 dB of device margin. Calibrate with real measurements for better accuracy.")
            }
        }
        .navigationTitle("How we calculate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BudgetRow: View {
    let title: LocalizedStringKey
    let value: String
    var indent = false
    var bold = false

    var body: some View {
        HStack {
            Text(title)
                .font(indent ? .footnote : .subheadline)
                .foregroundStyle(indent ? .secondary : .primary)
                .padding(.leading, indent ? 12 : 0)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit()).fontWeight(bold ? .bold : .regular)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Wall

private struct WallEditor: View {
    @Environment(FloorplanViewModel.self) private var model
    let wall: RFWallSegment
    @State private var scope: WallScope = .single

    var body: some View {
        Section {
            LabeledContent("Name", value: wall.name)
            LabeledContent("Length", value: Format.meters(wall.length))
            LabeledContent("Type", value: wall.isExterior ? String(localized: "Exterior") : String(localized: "Interior"))
            LabeledContent("Loss at \(model.band.displayName)", value: Format.decibels(wall.material.crossingLoss(for: model.band)))
        }

        Section {
            Picker("Apply to", selection: $scope) {
                Text("This one only").tag(WallScope.single)
                Text("Same material").tag(WallScope.sameMaterial)
                Text("All exterior").tag(WallScope.allExterior)
                Text("All interior").tag(WallScope.allInterior)
            }
            ForEach(choices) { material in
                Button {
                    model.setMaterial(material, forWalls: model.walls(for: scope, like: wall.id))
                } label: {
                    HStack {
                        Circle().fill(Color(hex: material.colorHex)).frame(width: 14, height: 14)
                        Text(material.name).foregroundStyle(.primary)
                        Spacer()
                        Text("−" + Format.decibels(material.crossingLoss(for: model.band)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if material.id == wall.material.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .frame(minHeight: 32)
                }
                .accessibilityAddTraits(material.id == wall.material.id ? .isSelected : [])
            }
        } header: {
            Text("Material")
        } footer: {
            Text(wall.isMaterialAuto ? "Material estimated automatically. Correct it if you know the real construction." : "Material you chose.")
        }
    }

    private var choices: [RFMaterial] {
        wall.kind == .obstacle ? RFMaterial.obstacleChoices : RFMaterial.wallChoices
    }
}

// MARK: - Access point

private struct AccessPointEditor: View {
    @Environment(FloorplanViewModel.self) private var model
    let ap: RFAccessPoint
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var confirmRemoval = false

    var body: some View {
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit { commitName(for: ap.id) }
                .accessibilityIdentifier("inspectorNameField")
            Stepper(value: Binding(get: { Int(ap.txPower) }, set: { value in model.updateAccessPoint(id: ap.id) { $0.txPower = Float(value) } }), in: 10...30) {
                LabeledContent("Power", value: Format.dbm(ap.txPower))
            }
            if let project = model.project {
                if project.floorCount > 1 {
                    Picker("Floor", selection: Binding(get: { ap.floor }, set: { value in model.updateAccessPoint(id: ap.id) { $0.floor = value } })) {
                        ForEach(0..<project.floorCount, id: \.self) { floor in
                            Text(floor == 0 ? String(localized: "Ground floor") : String(localized: "Floor \(floor)")).tag(floor)
                        }
                    }
                }
                Stepper("Horizontal position: \(Format.meters(ap.position.x))", value: Binding(get: { Double(ap.position.x) }, set: { model.moveAccessPoint(id: ap.id, to: SIMD2(Float($0), ap.position.y)) }), in: 0...Double(project.width), step: 0.25)
                Stepper("Vertical position: \(Format.meters(ap.position.y))", value: Binding(get: { Double(ap.position.y) }, set: { model.moveAccessPoint(id: ap.id, to: SIMD2(ap.position.x, Float($0))) }), in: 0...Double(project.depth), step: 0.25)
            }
            if !ap.isSatellite {
                Toggle(isOn: Binding(get: { ap.isLocked }, set: { value in model.updateAccessPoint(id: ap.id) { $0.isLocked = value } })) {
                    VStack(alignment: .leading) {
                        Text("Fixed position")
                        Text("For example, next to the fiber or cable inlet").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { name = ap.name }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName(for: ap.id) }
        }
        .onChange(of: ap.name) { _, newValue in
            name = newValue
        }
        .onDisappear { commitName(for: ap.id) }

        if ap.isSatellite {
            Section {
                Picker("Link to router", selection: Binding(get: { ap.backhaul }, set: { value in model.updateAccessPoint(id: ap.id) { $0.backhaul = value } })) {
                    Text("Wi-Fi").tag(BackhaulType.wireless)
                    Text("Ethernet cable").tag(BackhaulType.wired)
                }
                if let link = model.backhaul[ap.id] {
                    LabeledContent("Quality") {
                        Text(link.quality.title).foregroundStyle(link.quality.color)
                    }
                    if let rssi = link.rssi {
                        LabeledContent("Backhaul signal", value: Format.dbm(rssi))
                    }
                    LabeledContent("Connected to", value: model.accessPoint(id: link.parentId)?.name ?? "—")
                    LabeledContent("Available speed", value: Format.mbps(link.throughputMbps))
                }
            } header: {
                Text("Backhaul")
            } footer: {
                Text("For a Wi-Fi satellite to work well, the router signal where it sits should be −65 to −70 dBm or better.")
            }

            Section {
                Button("Remove satellite", role: .destructive) { confirmRemoval = true }
                    .confirmationDialog("Remove \(ap.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { model.removeAccessPoint(id: ap.id) }
                    }
            }
        }
    }

    private func commitName(for id: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = model.accessPoint(id: id), current.name != trimmed else {
            if id == ap.id, let current = model.accessPoint(id: id) { name = current.name }
            return
        }
        model.updateAccessPoint(id: id) { $0.name = trimmed }
    }
}

// MARK: - Room

private struct RoomDetail: View {
    @Environment(FloorplanViewModel.self) private var model
    let room: RoomInfo
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let coverage = model.roomCoverage.first { $0.id == room.id }
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit { commitName(for: room.id) }
                .accessibilityIdentifier("inspectorNameField")
            Picker("Type", selection: Binding(get: { room.kind }, set: { model.updateRoom(id: room.id, kind: $0) })) {
                ForEach(RoomKind.allCases) { kind in
                    Text(kind.baseName).tag(kind)
                }
            }
            LabeledContent("Area", value: Format.area(room.area))
        } footer: {
            Text("The type sets how much this room matters when finding the best placement.")
        }
        .onAppear { name = room.name }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName(for: room.id) }
        }
        .onChange(of: room.name) { _, newValue in
            name = newValue
        }
        .onDisappear { commitName(for: room.id) }
        if let coverage {
            Section("Coverage on \(model.band.displayName)") {
                LabeledContent("Area with good signal", value: Format.percent(coverage.summary.coveredPercent))
                LabeledContent("Typical signal", value: Format.dbm(coverage.summary.medianRSSI))
                LabeledContent("Worst 10%", value: Format.dbm(coverage.summary.p10RSSI))
                if let id = coverage.servingAccessPointId, let ap = model.accessPoint(id: id) {
                    LabeledContent("Served by", value: ap.name)
                }
                Button("Measure at the center of the room") {
                    model.placeProbe(at: room.labelPoint)
                    model.selection = nil
                }
            }
        }
    }

    private func commitName(for id: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = model.room(id: id), current.name != trimmed else {
            if id == room.id, let current = model.room(id: id) { name = current.name }
            return
        }
        model.updateRoom(id: id, name: trimmed)
    }
}

// MARK: - Rooms list

private struct RoomsSection: View {
    @Environment(FloorplanViewModel.self) private var model

    var body: some View {
        if !model.roomCoverage.isEmpty {
            Section("Rooms") {
                ForEach(model.roomCoverage) { room in
                    Button {
                        model.selection = .room(room.id)
                    } label: {
                        HStack {
                            Circle().fill(model.scale.uiColor(for: room.grade)).frame(width: 10, height: 10)
                            Text(room.name).foregroundStyle(.primary)
                            Spacer()
                            Text(Format.percent(room.summary.coveredPercent)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 32)
                    }
                    .accessibilityLabel(Text("\(room.name): \(Format.percent(room.summary.coveredPercent)) with good signal"))
                    .accessibilityIdentifier("inspectorRoom-\(room.name)")
                }
            }
        }
    }
}
