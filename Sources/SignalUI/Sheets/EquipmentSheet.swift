import SwiftUI
import SignalCore

/// Router, mesh, internet plan, construction style and map preferences.
struct EquipmentSheet: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var planText = ""

    var body: some View {
        NavigationStack {
            if let profile = model.project?.profile {
                form(profile)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<NetworkProfile, T>) -> Binding<T> {
        Binding(
            get: { (model.project?.profile ?? NetworkProfile())[keyPath: keyPath] },
            set: { value in model.updateProfile { $0[keyPath: keyPath] = value } }
        )
    }

    private func form(_ profile: NetworkProfile) -> some View {
        Form {
            Section {
                Picker("Wi-Fi standard", selection: binding(\.standard)) {
                    ForEach(WifiStandard.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper(value: binding(\.clientStreams), in: 1...4) {
                    LabeledContent("Device antennas", value: profile.clientStreams.formatted())
                }
                Picker("Width on 5 GHz", selection: binding(\.channelWidth5)) {
                    ForEach([20, 40, 80, 160], id: \.self) { Text("\($0) MHz").tag($0) }
                }
                if profile.supportedBands.contains(.six) {
                    Picker("Width on 6 GHz", selection: binding(\.channelWidth6)) {
                        ForEach([80, 160, 320], id: \.self) { Text("\($0) MHz").tag($0) }
                    }
                }
            } header: {
                Text("Router")
            } footer: {
                Text("Phones and laptops usually have 2 antennas. The standard is on the box or on the router label.")
            }

            Section {
                Toggle("Tri-band kit (dedicated backhaul)", isOn: binding(\.dedicatedBackhaulRadio))
                if profile.supportedBands.contains(.six) {
                    Picker("Backhaul band", selection: binding(\.backhaulBand)) {
                        Text(RFBand.five.displayName).tag(RFBand.five)
                        Text(RFBand.six.displayName).tag(RFBand.six)
                    }
                }
            } header: {
                Text("Mesh network")
            } footer: {
                Text("Without a dedicated radio, each wireless hop between satellites cuts speed to about half.")
            }

            Section {
                TextField("Plan speed (Mbps)", text: $planText)
                    .keyboardType(.numberPad)
                    .onAppear { planText = profile.internetPlanMbps > 0 ? String(profile.internetPlanMbps) : "" }
                    .onChange(of: planText) { _, text in
                        let digits = text.filter(\.isNumber)
                        model.updateProfile { $0.internetPlanMbps = Int(digits) ?? 0 }
                    }
            } header: {
                Text("Internet")
            } footer: {
                Text("Used to show the real internet speed at each point.")
            }

            Section {
                Picker("Interior walls", selection: binding(\.construction)) {
                    Text("Masonry (brick)").tag(ConstructionProfile.masonry)
                    Text("Drywall").tag(ConstructionProfile.drywall)
                    Text("Concrete").tag(ConstructionProfile.concrete)
                }
            } header: {
                Text("Construction")
            } footer: {
                Text("Updates walls with automatic material. Walls you edited stay as they are.")
            }

            Section {
                Picker("Signal considered good", selection: binding(\.coverageThreshold)) {
                    Text("−60 dBm (strict)").tag(Float(-60))
                    Text("−67 dBm (recommended)").tag(Float(-67))
                    Text("−70 dBm (basic)").tag(Float(-70))
                }
                Picker("Map colors", selection: binding(\.palette)) {
                    Text("Standard").tag(HeatmapPalette.standard)
                    Text("Color-blind friendly").tag(HeatmapPalette.colorblindSafe)
                }
                VStack(alignment: .leading) {
                    Text("Heatmap opacity")
                    Slider(value: Binding(get: { model.heatmapOpacity }, set: { model.heatmapOpacity = $0 }), in: 0...1)
                        .accessibilityLabel("Heatmap opacity")
                }
            } header: {
                Text("Map")
            }
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }
            }
        }
    }
}
