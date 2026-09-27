// swift-tools-version: 6.0
import PackageDescription

// The iOS UI (SignalUI, SignalApp) builds through Signal.xcodeproj (generated from project.yml).
// This package builds the platform-independent core, its tests and a command-line verification runner.
let package = Package(
    name: "SignalCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SignalCore", targets: ["SignalCore"]),
        .executable(name: "SignalTestRunner", targets: ["SignalTestRunner"])
    ],
    targets: [
        .target(
            name: "SignalCore",
            path: "Sources/SignalCore"
        ),
        .executableTarget(
            name: "SignalTestRunner",
            dependencies: ["SignalCore"],
            path: "Sources/SignalTestRunner"
        ),
        .testTarget(
            name: "SignalCoreTests",
            dependencies: ["SignalCore"],
            path: "Tests/SignalCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
