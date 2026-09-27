# Signal — Wi-Fi with LiDAR (iOS)

Scan your home with LiDAR, mark where the router is, and see the estimated Wi-Fi signal in every room. The app suggests the best position for the router and mesh satellites, and shows the signal map on the floor in augmented reality.

The app is English-only; there are no in-app translations.

## What the app does

- **Whole-home scan (RoomPlan):** room by room in the same AR session, merged with `StructureBuilder`; supports multiple floors. During the scan, the “I'm next to the router” button records the real router position.
- **RF-ready floor plan:** the plan is aligned to the axes, corners are closed, walls are cut at doors, windows, and openings, and objects (refrigerator, cabinets, bathtub, and so on) become obstacles. Materials follow the construction profile (masonry, drywall, or concrete) and can be corrected wall by wall or in bulk.
- **Single propagation model:** free space + per-wall loss (higher at an angle) + first-order reflections + floor slab between stories. The map, coverage, rooms, measurement point, and optimizer all use the same calculation.
- **Realistic speed:** noise by channel width, MCS by Wi-Fi standard (5/6/6E/7), real throughput (~60% of PHY rate) limited by satellite backhaul and the internet plan.
- **Mesh:** backhaul tree (each satellite links to the router or another satellite), Ethernet option, tri-band kit.
- **Best placement:** optimizes the router and satellites together inside the home, away from walls and furniture, with backhaul ≥ −70 dBm; recommends how many satellites are needed; preview on the map, apply, and undo.
- **Calibration:** real measurements (AirPort Utility or the router’s app) tune the model.
- **Augmented reality:** relocalizes with the environment map saved at the end of the scan and projects the heatmap on the floor, with live signal where the phone is.
- **Projects:** multiple projects, bounded backups, `.signalsim` file to share and import, PDF report, export to the web simulator.
- **Accessibility:** VoiceOver actions to move the router and the measurement point, Dynamic Type, color-blind-friendly palette.

## Layout

| Folder | Contents |
| :--- | :--- |
| `Sources/SignalCore` | Platform-independent core: models, propagation engine, signal field, optimizer, backhaul, calibration, RoomPlan converter, persistence, and view model. |
| `Sources/SignalUI` | SwiftUI interface (iOS): projects, scan, map, sheets, AR, and report. |
| `Sources/SignalApp` | App entry point. |
| `Tests/SignalCoreTests` | Core tests (Swift Testing). |
| `Sources/SignalTestRunner` | Command-line verification and benchmark. |
| `docs/` | Original specification (01–08) and the technical review with the improvement plan (09). |

## Build

```bash
xcodegen generate                      # project.yml is the source of the Xcode project
swift test                             # core tests on macOS
swift run -c release SignalTestRunner  # verification and benchmark
```

Requirements: iOS 17+, Swift 6. Scanning requires an iPhone or iPad Pro with LiDAR; without LiDAR, the demo and import remain available.
