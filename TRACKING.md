# Implementation status

> Updated 27/09/2026 · version 1.1.0 (build 2). The full plan and the rationale for each item are in [docs/09-revisao-e-plano.md](./docs/09-revisao-e-plano.md).

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
| App Store (privacy manifest, metadata) | Pending | Out of scope for this stage. |

## Verification

- `swift test`: 50 tests in 6 suites (propagation, converter, field/scale/rate, optimizer/calibration, persistence, real-scan repair).
- `swift run -c release SignalTestRunner`: map × inspector consistency and timings (full field ~1 ms, optimizer ~20 ms on the demo, Mac M-series).
- App build in Swift 6 with no warnings.

## To validate on iPhone

1. Scan of two or more rooms with “Next room” and assembly of the plan.
2. Router position marked during the scan.
3. Open doors letting signal through on the map.
4. Heatmap orientation on the floor in AR mode.
