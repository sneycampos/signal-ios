# 01. Architecture

What Mesh Planner does, how the code is organized, and the rules that keep it consistent.

---

## 1. Product

Mesh Planner (store name *Wi-Fi Mesh Planner: LiDAR Scan*) turns a LiDAR scan of a home into a Wi-Fi coverage map and finds the best positions for the router and mesh satellites.

1. **Scan** the home room by room with RoomPlan, marking where the router is ([02](02-lidar-capture-roomplan.md)).
2. The scan becomes an **RF floor plan**: walls cut at doors and windows, materials per wall, appliances as obstacles, rooms and floors ([04](04-materials-and-semantics.md)).
3. A **propagation model** estimates the signal everywhere ([03](03-rf-propagation-engine.md)); the map shows coverage per room and the signal, speed and calculation at any point ([05](05-interactive-ui-ux.md)).
4. **Best placement** proposes router and satellite positions, compared with the current layout before anything is applied ([10](10-placement-optimizer.md)).
5. **Calibration** with real measurements tunes the model; **AR** draws the map on the real floor ([06](06-ar-floor-overlay.md)); projects can be shared, imported and exported as a PDF report ([07](07-export-sync-and-sharing.md)).

Everything runs on the device: no account, no network calls, no analytics. The app is English only.

## 2. Targets and modules

| Target | Kind | Contents |
| :--- | :--- | :--- |
| `MeshPlannerCore` | Framework and Swift package library | Models, propagation engine, signal field, optimizer, backhaul, calibration, RoomPlan conversion (on plain structs), persistence and `FloorplanViewModel`. No UIKit, RoomPlan or ARKit, so it builds and tests on macOS. |
| `MeshPlannerUI` | Framework | SwiftUI screens, RoomPlan capture, AR walkthrough, sheets, PDF report. |
| `MeshPlanner` | iOS app | `Sources/SignalApp/AppMain.swift`: creates the shared view model and the window. |
| `SignalTestRunner` | Command-line tool | Consistency checks and timings (`swift run -c release SignalTestRunner`). |
| `MeshPlannerCoreTests` | Swift Testing | Core tests, run with `swift test`. |
| `MeshPlannerUITests` | XCUITest | End-to-end tests in the iOS Simulator. |

The Xcode project is generated from `project.yml` with XcodeGen; `Package.swift` builds the core, the runner and the core tests. Swift 6 language mode with complete strict concurrency, iOS 17+, iPhone (portrait) and iPad.

```
Sources/
├── SignalApp/            app entry point
├── MeshPlannerUI/
│   ├── AppRootView.swift navigation, import, scan entry, error alert
│   ├── Home/             project list, demo, scan and import buttons
│   ├── Map/              map screen, canvas, plan drawing, legend, band picker
│   ├── Sheets/           inspector, equipment, optimizer, calibration, diagnostics, report
│   ├── Scan/             ScanController, RoomScanView, RoomPlanExtraction
│   ├── AR/               ARWalkthroughView
│   ├── Report/           ReportRenderer (PDF)
│   └── Style/            theme, colours, document types, support links
└── MeshPlannerCore/
    ├── Engine/           RFPropagationEngine (PropagationModel), SignalField,
    │                     PlacementOptimizer, BackhaulPlanner, LinkRateModel, Calibrator
    ├── Converters/       RoomPlanConverter, ProjectRepair
    ├── Geometry/         Geometry, RoomRegionDetector, RoomLabelLayout
    ├── Models/           FloorplanProject, walls, APs, materials, bands, rooms,
    │                     NetworkProfile, SignalScale, DefaultApartmentFixture
    ├── Serialization/    ProjectStore, validation, web export, logger
    └── ViewModels/       FloorplanViewModel
```

## 3. Data flow

```
RoomPlan (device) ──RoomPlanExtraction──▶ RoomPlanCapture (plain structs)
                                              │ RoomPlanConverter
                                              ▼
                   ProjectStore ◀──save/load── FloorplanProject ──▶ FloorplanViewModel (@MainActor)
                   (actor, files)                                    │
                                    ┌──────────────┬─────────────────┼───────────────┬──────────────┐
                                    ▼              ▼                 ▼               ▼              ▼
                           SignalFieldGenerator  linkBudget   PlacementOptimizer  BackhaulPlanner  Calibrator
                                    └──────────────┴──── PropagationModel (one model) ┴──────────────┘
                                                             │
                                                             ▼
                                           Map, inspector, optimizer sheet, AR, PDF
```

`FloorplanProject` is the single source of truth: walls, access points, rooms, furniture, network profile, calibration, measurements, probe, alignment for AR and the selected band. Every edit goes through the view model, which snapshots the project for undo, recomputes what changed and schedules a save.

## 4. Rules that keep the numbers consistent

1. **One propagation model.** The heatmap, coverage percentage, room grades, point inspector, backhaul, calibration and optimizer all use `PropagationModel` with reflections. Tests check that the inspector equals the map at the same point.
2. **One signal scale.** `SignalScale` defines thresholds, colours and labels for the map, legend, room chips, gauge, report and AR.
3. **One coverage definition.** Coverage counts only cells inside rooms (`InteriorMask`). The map's final grid (0.1 m) is also the grid the optimizer sheet uses for Before/After, so the numbers match.
4. **Best server.** A point is served by its strongest AP; powers are never summed across APs.
5. **Never worse.** The optimizer's proposal is compared with the current layout and is only offered when it is clearly better.

## 5. Coordinates and units

- Metres everywhere. The plan's `x` is RoomPlan world X and the plan's `y` is world Z; world Y is height.
- The converter rotates the scan so the walls line up with the axes and shifts it so the plan starts 0.3 m from the origin. `WorldAlignment` (rotation, offset, floor elevations) converts plan points back to world points for AR.
- Floors are indexed from 0 (ground floor); each wall, room, AP and measurement has a floor.
- Signal values are dBm as `Float`.

## 6. Concurrency

- `FloorplanViewModel` is `@MainActor @Observable`. Heavy work runs in detached tasks: the heatmap (live and full grids), backhaul, the optimizer, calibration, RoomPlan conversion and project thumbnails.
- Every job takes a `CancellationToken` (a `Sendable` lock-protected flag) checked inside `concurrentPerform` loops, and a generation counter drops results that arrive after a newer request.
- While dragging, live heatmap requests are coalesced: one in flight and at most one pending. Releasing the node cancels them and runs the full grid.
- `ProjectStore` is an actor, so disk I/O never runs on the main actor. Saving is debounced (800 ms) and flushed when switching projects, closing, or entering the background.

## 7. Performance

Measured with `SignalTestRunner` (release build, M-series Mac) on the demo apartment (14 × 10 m), October 2026:

| Work | Time | Guard |
| :--- | :--- | :--- |
| Full heatmap, 0.1 m grid (14,000 cells) | about 2 ms | Parallel over rows. |
| Optimizer, router + 0–3 satellites (automatic) | about 55 ms | Test budget: < 1,500 ms in a debug build; router only < 600 ms. |

Run `swift run -c release SignalTestRunner` for current numbers.

## 8. Privacy

- No account, analytics, tracking or network requests. Scans, projects and world maps stay in the app's folders until the user shares them.
- The camera is used only for scanning and the AR walkthrough.
- `Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data, and one required-reason API: file timestamps (`C617.1`), used to space backups.
