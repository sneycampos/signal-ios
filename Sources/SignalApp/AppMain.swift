import SwiftUI
import SignalCore
import SignalUI
import UIKit

@main
struct SignalApp: App {
    @State private var model = FloorplanViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save project")
                    Task { @MainActor in
                        await model.flushSave()
                        if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
                    }
                }
        }
    }
}
