import SwiftUI
import SignalCore

/// Projects list → map, plus scanning, importing and opening shared `.signalsim` files.
public struct AppRootView: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.openURL) private var openURL
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-demo") {
                await model.prepareUITestDemo()
                return
            }
            #endif
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
        .onChange(of: model.project?.id) {
            if model.project != nil {
                showScan = false
                showImporter = false
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { !showScan && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.hasUnsavedChanges {
                Button("Retry saving") { Task { await model.flushSave() } }
            }
            if ScanAvailability.current == .cameraDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
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
