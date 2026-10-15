import SwiftUI
import SignalCore
import SignalUI
import UIKit

@main
struct SignalApp: App {
    @State private var model = FloorplanViewModel()
    @State private var backgroundSave = BackgroundProjectSave()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
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
