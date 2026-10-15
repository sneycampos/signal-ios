import SwiftUI
import SignalCore
import SignalUI
import UIKit

@main
struct SignalApp: App {
    @State private var model: FloorplanViewModel = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-demo") {
            UIView.setAnimationsEnabled(false)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("signal-uitest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return FloorplanViewModel(store: ProjectStore(rootDirectory: root))
        }
        #endif
        return FloorplanViewModel()
    }()
    @State private var backgroundSave = BackgroundProjectSave()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
                #if DEBUG
                .transaction { transaction in
                    if ProcessInfo.processInfo.arguments.contains("-uitest-demo") {
                        transaction.disablesAnimations = true
                    }
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    backgroundSave.start(model: model)
                }
        }
    }
}

@MainActor
private final class BackgroundProjectSave {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var saving = false

    func start(model: FloorplanViewModel) {
        guard !saving else { return }
        saving = true
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save project") { [weak self] in
            Task { @MainActor in self?.end() }
        }
        Task {
            await model.flushSave()
            end()
            saving = false
        }
    }

    private func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
