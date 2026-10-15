import SwiftUI
import MeshPlannerCore

private enum SatelliteChoice: Hashable {
    case automatic
    case count(Int)

    var option: SatelliteCountOption {
        switch self {
        case .automatic: return .automatic
        case .count(let n): return .exactly(n)
        }
    }
}

/// Finds the best router/satellite positions, previews them on the map and applies them with undo.
struct OptimizerSheet: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choice: SatelliteChoice = .automatic
    @State private var lockRouter = false

    var body: some View {
        NavigationStack {
            Form {
                switch model.optimizer {
                case .idle, .failed:
                    options
                    if case .failed(let message) = model.optimizer {
                        Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                case .running(let progress):
                    Section {
                        ProgressView(value: progress) {
                            Text("Trying positions…")
                        }
                        Button("Cancel", role: .cancel) { model.cancelOptimizer() }
                    }
                case .ready(let comparison):
                    result(comparison)
                }
            }
            .navigationTitle("Best placement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .ready = model.optimizer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Discard") { model.discardOptimizerResult() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            model.applyOptimizerResult()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("applyPlacement")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .onAppear {
                lockRouter = model.project?.router?.isLocked ?? false
                let current = min(6, model.project?.satellites.filter { $0.floor == model.floor }.count ?? 0)
                choice = current > 0 ? .count(current) : .automatic
            }
        }
    }

    private var options: some View {
        Group {
            Section {
                if model.project?.router?.floor == model.floor {
                    Toggle(isOn: $lockRouter) {
                        VStack(alignment: .leading) {
                            Text("Keep the router where it is")
                            Text("Turn on if it depends on the fiber outlet or cable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                let maxSatellites = max(3, min(6, model.project?.satellites.filter { $0.floor == model.floor }.count ?? 0))
                Picker("Mesh satellites", selection: $choice) {
                    Text("Recommend how many").tag(SatelliteChoice.automatic)
                    Text("None").tag(SatelliteChoice.count(0))
                    ForEach(1...maxSatellites, id: \.self) { n in
                        Text("\(n)").tag(SatelliteChoice.count(n))
                    }
                }
            } footer: {
                Text("Looks for positions indoors, away from walls and furniture, that maximize the area with good signal on \(model.project?.profile.planningBand.displayName ?? "5 GHz"). Each Wi-Fi satellite needs backhaul of at least −70 dBm.")
            }
            Section {
                Button {
                    model.runOptimizer(satellites: choice.option, lockRouter: lockRouter)
                } label: {
                    Label("Calculate", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func result(_ comparison: OptimizerComparison) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text("Before").font(.caption).foregroundStyle(.secondary)
                    Text(Format.percent(comparison.before.coveredPercent)).font(.title2.bold())
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                VStack(alignment: .trailing) {
                    Text("After").font(.caption).foregroundStyle(.secondary)
                    Text(Format.percent(comparison.after.coveredPercent)).font(.title2.bold()).foregroundStyle(.green)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Coverage from \(Format.percent(comparison.before.coveredPercent)) to \(Format.percent(comparison.after.coveredPercent))"))
            if comparison.satellitesToAdd == 1 {
                Label("Add 1 satellite", systemImage: "plus.circle")
            } else if comparison.satellitesToAdd > 1 {
                Label("Add \(comparison.satellitesToAdd) satellites", systemImage: "plus.circle")
            }
            if comparison.satellitesToRemove == 1 {
                Label("1 satellite is no longer needed", systemImage: "minus.circle")
            } else if comparison.satellitesToRemove > 1 {
                Label("\(comparison.satellitesToRemove) satellites are no longer needed", systemImage: "minus.circle")
            }
            if comparison.after.coveredPercent < comparison.before.coveredPercent + 1 {
                Text("The current placement is already close to the best possible.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Area with good signal on \(comparison.band.displayName)")
        } footer: {
            Text("New positions appear on the map as dashed circles.")
        }

        Section("By room") {
            ForEach(comparison.roomsAfter) { after in
                let before = comparison.roomsBefore.first { $0.id == after.id }
                HStack {
                    Text(after.name)
                    Spacer()
                    Text("\(Format.percent(before?.summary.coveredPercent ?? 0)) → \(Format.percent(after.summary.coveredPercent))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Button {
                model.applyOptimizerResult()
                dismiss()
            } label: {
                Text("Apply positions").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Button("Discard", role: .cancel) { model.discardOptimizerResult() }
                .frame(maxWidth: .infinity)
        }
    }
}
