import SwiftUI
import SignalCore
import SignalUI

@main
struct SignalApp: App {
    @State private var model = FloorplanViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
        }
    }
}
