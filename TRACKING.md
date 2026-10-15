# Implementation status

> Updated 15/10/2026 · version 1.1.0 (build 3). The full plan and the rationale for each item are in [docs/09-review-and-plan.md](./docs/09-review-and-plan.md).

## Summary

| Area | Status | Notes |
| :--- | :---: | :--- |
| Multi-room, multi-floor RoomPlan scan | Implemented | Validate in a real home on device. |
| Mark the router during the scan | Implemented | Camera pose from the ARSession. |
| Cut-out of doors/windows/openings | Implemented | By `parentIdentifier` or geometric overlap. Covered by tests. |
| Objects as obstacles (rotated, per instance) | Implemented | Covered by tests. |
| Rooms from `floors` + `sections` | Implemented | Convex hull as fallback. |
| Material classification by construction profile | Implemented | Exterior wall from the outside of rooms. |
| Single propagation engine | Implemented | Map = inspector = coverage (tested). |
| Interior mask | Implemented | Coverage only inside the home. |
| Rate/throughput by Wi-Fi standard and channel width | Implemented | |
| Mesh backhaul (tree, cable, tri-band) | Implemented | |
| Router + satellite optimizer | Implemented | Preview, apply, undo, cancel. |
| Calibration from measurements | Implemented | Adjusts exponent, wall scale, and offset. |
| AR with heatmap on the floor | Implemented | Requires a project scanned with this version. Validate orientation on device. |
| Projects, backups, `.signalsim`, PDF | Implemented | |
| Accessibility, English-only | Implemented | No in-app translations. |
| App Store (privacy manifest, metadata) | Implemented | Privacy manifest bundled in app and framework; metadata and support links included. |

## Verification

- `swift test`: 104 tests in 9 suites (propagation, converter, field/scale/rate, optimizer/calibration, optimizer never worse, persistence, legacy-scan repair, room label layout, review regressions). See [docs/08](./docs/08-testing-and-benchmarking.md).
- `scripts/ui-test.sh`: 8 XCUITests in the simulator (7 run, 1 skipped).
- `swift run -c release SignalTestRunner`: map × inspector consistency and timings (full field ~2 ms, optimizer with 0–3 satellites ~55 ms on the demo, Mac M-series).
- App build in Swift 6 with no warnings.

## To validate on iPhone

1. Scan of two or more rooms with “Next room” and assembly of the plan.
2. Router position marked during the scan.
3. Open doors letting signal through on the map.
4. Heatmap orientation on the floor in AR mode.
