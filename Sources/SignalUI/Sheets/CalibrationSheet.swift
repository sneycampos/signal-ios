import SwiftUI
import SignalCore

/// Real readings entered by the user tune the model (path-loss exponent, wall losses, offset).
struct CalibrationSheet: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var result: Calibrator.Result?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Measure the signal with AirPort Utility (turn on “Wi-Fi Scanner” in the app’s Settings) or with your router’s app. Place the yellow pin where you are and enter the value.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let probe = model.probe {
                        LabeledContent("Current point", value: probe.roomName ?? String(localized: "Outside rooms"))
                        LabeledContent("The model predicts", value: Format.dbm(probe.rssi))
                    }
                    HStack {
                        TextField("e.g. −62", text: $valueText)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($fieldFocused)
                        Text("dBm").foregroundStyle(.secondary)
                    }
                    Button("Add reading on \(model.band.displayName)") {
                        if let value = parsedValue {
                            model.addMeasurement(rssi: value)
                            valueText = ""
                            fieldFocused = false
                        }
                    }
                    .disabled(parsedValue == nil)
                } header: {
                    Text("New measurement")
                }

                if let measurements = model.project?.measurements, !measurements.isEmpty {
                    Section("Measurements (\(measurements.count))") {
                        ForEach(measurements) { m in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.project?.room(containing: m.position, floor: m.floor)?.name ?? String(localized: "Point"))
                                    Text(m.band.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Format.dbm(m.rssi)).monospacedDigit()
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.removeMeasurement(id: measurements[index].id) }
                        }
                    }

                    Section {
                        Button("Calibrate model") { Task { result = await model.runCalibration() } }
                        if let result {
                            LabeledContent("Average error before", value: Format.decibels(result.rmsBefore))
                            LabeledContent("Average error after", value: Format.decibels(result.rmsAfter))
                        }
                    } footer: {
                        Text("With 3 or more measurements in different rooms, the app also adjusts wall loss and distance attenuation.")
                    }
                }

                if let calibration = model.project?.calibration, calibration.isCalibrated {
                    Section("Active calibration") {
                        LabeledContent("Distance exponent", value: calibration.pathLossExponent.formatted(.number.precision(.fractionLength(1))))
                        LabeledContent("Wall scale", value: calibration.wallLossScale.formatted(.number.precision(.fractionLength(1))))
                        LabeledContent("Overall offset", value: Format.decibels(calibration.offsetDb))
                        Button("Reset to the default model", role: .destructive) {
                            model.resetCalibration()
                            result = nil
                        }
                    }
                }
            }
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private var parsedValue: Float? {
        let normalized = valueText
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard var value = Float(normalized) else { return nil }
        if value > 0 { value = -value }
        return (-110...(-10)).contains(value) ? value : nil
    }
}
