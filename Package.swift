// swift-tools-version: 6.0
import PackageDescription

// The iOS UI (MeshPlannerUI, SignalApp) builds through MeshPlanner.xcodeproj (generated from project.yml).
// This package builds the platform-independent core, its tests and a command-line verification runner.
let package = Package(
    name: "MeshPlannerCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MeshPlannerCore", targets: ["MeshPlannerCore"]),
        .executable(name: "SignalTestRunner", targets: ["SignalTestRunner"])
    ],
    targets: [
        .target(
            name: "MeshPlannerCore",
            path: "Sources/MeshPlannerCore"
        ),
        .executableTarget(
            name: "SignalTestRunner",
            dependencies: ["MeshPlannerCore"],
            path: "Sources/SignalTestRunner"
        ),
        .testTarget(
            name: "MeshPlannerCoreTests",
            dependencies: ["MeshPlannerCore"],
            path: "Tests/MeshPlannerCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
