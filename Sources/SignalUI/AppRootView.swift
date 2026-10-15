import SwiftUI
import SignalCore

/// Projects list → map, plus scanning, importing and opening shared `.signalsim` files.
public struct AppRootView: View {
    @Environment(FloorplanViewModel.self) private var model
    @State private var showScan = false
    @State private var showImporter = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ProjectsHomeView(onScan: startScan, onImport: { showImporter = true })
                .navigationDestination(isPresented: Binding(get: { model.isProjectOpen }, set: { if !$0 { Task { await model.close() } } })) {
                    MapScreen()
                }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-openDemo") { await model.openDemo() }
            #endif
        }
        .fullScreenCover(isPresented: $showScan) {
            RoomScanView()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.signalProject, .json]) { result in
            if case .success(let url) = result {
                Task { await model.importProject(from: url) }
            }
        }
        .onOpenURL { url in
            Task { await model.importProject(from: url) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Retry saving") { Task { await model.flushSave() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func startScan() {
        Task {
            guard ScanAvailability.current != .unsupportedDevice else { return }
            guard await ScanAvailability.requestCamera() else {
                model.errorMessage = "Allow camera access in Settings to scan your home."
                return
            }
            if model.isProjectOpen { await model.close() }
            guard !model.isProjectOpen else { return }
            showScan = true
        }
    }
}
