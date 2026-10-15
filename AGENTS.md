# Repository Guidelines

## Project Structure & Module Organization

Mesh Planner (Xcode target `MeshPlanner`) is an iOS 17+ Wi-Fi coverage planner built with Swift 6 and SwiftUI.

- `Sources/MeshPlannerCore/`: models, RF propagation, geometry, optimization, calibration, persistence, and `FloorplanViewModel`.
- `Sources/MeshPlannerUI/`: SwiftUI screens, RoomPlan capture, AR overlays, sheets, and PDF reporting.
- `Sources/SignalApp/AppMain.swift`: app entry point and shared model injection.
- `Sources/SignalTestRunner/`: command-line verification and benchmarks.
- `Tests/MeshPlannerCoreTests/`: core tests; fixtures are built in code (`DefaultApartmentFixture`, synthetic captures).
- `Tests/MeshPlannerUITests/`: end-to-end XCUITests in the iOS Simulator.
- `Resources/`: asset catalog, Info.plist, and privacy manifest. `docs/` holds specifications; `site/` holds the static website.

Keep RoomPlan/ARKit integration in MeshPlannerUI and reusable calculations in MeshPlannerCore. Map, inspector, coverage, and optimizer must share the propagation model.

## Build, Test, and Development Commands

Use Xcode 26+ (iOS 26 SDK) with Swift 6 and XcodeGen. Run commands from the repository root:

```bash
xcodegen generate                      # regenerate MeshPlanner.xcodeproj
open MeshPlanner.xcodeproj             # select MeshPlanner and run in Xcode
swift test                             # core tests on macOS 14+
swift test --filter PropagationModelTests
swift run -c release SignalTestRunner   # consistency checks and benchmarks
xcodebuild -project MeshPlanner.xcodeproj -scheme MeshPlanner \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Edit `project.yml` for target/build configuration, then regenerate the Xcode project.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types/files, and `lowerCamelCase` members. Follow surrounding Swift style; no formatter or linter is configured. Preserve Swift 6 strict concurrency, `Sendable` boundaries, and the `@MainActor @Observable` view model. Keep app-facing strings in English.

## Testing Guidelines

Use Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), with `<Feature>Tests.swift` files and descriptive behavior names. Add regression cases for changed RF calculations, scan conversion, or persistence. No numeric coverage threshold is configured.

Run `swift test` for core changes; compile the app for UI changes because package tests exclude MeshPlannerUI. Validate scanning and AR alignment on a physical LiDAR device; simulator demo/import checks cannot cover capture.

## Commit & Pull Request Guidelines

History uses short, descriptive subjects, sometimes prefixed by area, such as `Metadata: remove signal/sinal keyword`. Keep commits focused. PRs should describe the behavior change, link relevant issues, report validation and device limitations, and include screenshots for UI changes.

## Agent Workflow

Prefix shell commands with `rtk`; use `rtk proxy` for unsupported commands. Preserve unrelated working-tree changes, stay within scope, and report checks that could not run.
