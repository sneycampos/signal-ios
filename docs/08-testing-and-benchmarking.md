# 08. Testing and benchmarks

What is tested, how to run it, and what can only be checked on a real device.

---

## 1. Quick reference

| Command | What it runs | Where |
| :--- | :--- | :--- |
| `swift test` | 104 core tests in 9 suites (Swift Testing) | macOS 14+ |
| `swift test --filter PropagationModelTests` | One suite (any suite or test name works) | macOS |
| `swift run -c release SignalTestRunner` | Consistency checks and timings | macOS |
| `./scripts/test.sh [--runner] [--build-app]` | `swift test`, optionally the runner and an app build | macOS |
| `./scripts/ui-test.sh [--headless]` | XCUITest suite in the iOS Simulator | Simulator |
| `./scripts/build.sh` | Simulator build without signing; `--run --demo` launches the demo | Simulator |

`swift test` does not build `MeshPlannerUI`. After UI changes, compile the app (`./scripts/build.sh` or the `xcodebuild` command in the [README](../README.md)) or run the UI tests. The scripts require Xcode 26 or newer with the iOS 26 SDK.

## 2. Core tests (`Tests/MeshPlannerCoreTests`)

| Suite | File | Tests | Covers |
| :--- | :--- | :---: | :--- |
| Propagation model | `PropagationModelTests.swift` | 14 | Band ordering, metal shadows, transparent materials, reflections never weaken the direct path, obstacles counted once per object, wall joints do not leak, small scan gaps, inspector equals map, best server (not the sum), slab loss, calibration scaling. |
| RoomPlan conversion | `RoomPlanConverterTests.swift` | 10 | Door and opening cuts, clear glass windows, axis alignment of rotated scans, obstacles, rooms from floors and sections, router marker inside the home, `WorldAlignment` round trip, perimeter partitions stay interior, corner welding. |
| Signal field, scale and link rate | `FieldAndScaleTests.swift` | 8 | Coverage counts only the interior, demo coverage matches the probe, contours follow the threshold, grades and colours share thresholds, noise floor by width, link rate, backhaul limits, satellite chaining. |
| Placement optimizer and calibration | `OptimizerAndCalibrationTests.swift` | 6 | Positions inside and off furniture, backhaul respected, more nodes never lower coverage, locked router stays, cancellation, calibration recovers a known model. |
| Optimizer never worse | `OptimizerNeverWorseTests.swift` | 16 | The proposal is never worse than the current layout, router-only results are independent of the start and within 1 point of brute-force references, `compare()` matches the map, locked nodes, inactive satellites, tall plans, performance budgets. See [10 §5](10-placement-optimizer.md#5-accuracy-and-verification). |
| Project store | `ProjectStoreTests.swift` | 8 | Save, list, load and delete; demo never saved; bounded backups; export/import round trip; web documents; legacy scan migration; malformed materials; renamed projects folder. |
| Legacy scan repair | `RealScanTests.swift` | 4 | Every enclosed region becomes a room, no wall overlaps an opening, the heatmap fills every room, interior partitions are not brick. |
| Room label layout | `RoomLabelLayoutTests.swift` | 4 | Labels never overlap, layout is deterministic, panning moves labels rigidly, labels do not move while dragging the pin or a router. |
| Review regressions | `ReviewRegressionTests.swift` | 34 | One test per bug fixed in the reviews ([09](09-review-and-plan.md)): validation limits, save flushing and retry, optimizer invalidation, multi-floor paths and backhaul, world map handling, recovery from damaged files, live drag updates. |

Tests build their fixtures in code (`DefaultApartmentFixture`, a synthetic legacy scan and small hand-built captures and projects) and use temporary folders for `ProjectStore`. Tests that use the view model run on the main actor.

### Optimizer references

The router-only references were computed once by brute force: every position on a fine grid scored with `SignalFieldGenerator` (reflections on) and the best candidates re-scored on the map's grid. The values are written in the test file with the method, so they can be recomputed if the model changes. Any change to the propagation model that moves these numbers must update the references on purpose.

## 3. UI tests (`Tests/MeshPlannerUITests`)

| Test | Checks |
| :--- | :--- |
| `testSmokeProjectListOpenMapBandToggleAndOptimizeSheet` | Open the project, switch bands, open the optimizer sheet. |
| `testRoomLabelFramesUnchangedDuringProbeAndRouterDrag` | Room labels stay put while dragging. |
| `testHeatmapUpdatesMidDragDuringRouterDrag` | Live heatmap publishes during a drag and a full one after it. |
| `testUndoAfterFloorSwitch` | Undo works across a floor change. |
| `testInspectorNameEditsSavedOnFocusLossWithoutRenamingOtherSelection` | Inspector text fields save to the right element. |
| `testRouterOnlyOptimizeMatchesMapAndIsAlreadyBestAfterApply` | The optimizer's Before equals the map's percentage; after applying, a second run reports "already the best". |
| `testFakeScanFailureWhileWarningOrCancelDialogOpen` | Scan error paths with dialogs open. |
| `testImportRenamedSignalsimDuplicate` | Skipped: the system document picker cannot be driven; covered by a core test instead. |

### Launch arguments (Debug builds only)

| Argument | Effect |
| :--- | :--- |
| `-uitest-demo` | Uses a fresh temporary folder for projects, turns animations off, grants camera access and saves a demo-based project with a second floor. |
| `-uitest-fake-scan-failure` | Fakes a scan session that fails, without a camera. |
| `-openDemo` | Opens the demo apartment at launch. |
| `-openSheet inspector\|equipment\|calibration\|optimizer\|perspective` | Opens a sheet or the 3D view after launch (used for screenshots). |

A hidden `heatmap` element exposes `generation=N,live=M` so tests can wait for heatmap updates. Other identifiers include `mapCoveragePercent`, `bandToggle`, `band-<band>`, `router`, `satellite`, `probe`, `roomLabel-<name>`, `addSatellite`, `optimize`, `undo`, `mapLayers`, `backToProjects`, `satelliteCountPicker`, `optimizerAlreadyOptimal` and `optimizerCoverageChange`.

## 4. SignalTestRunner

`swift run -c release SignalTestRunner` loads the demo apartment and prints `[PASS]`/`[FAIL]` lines:

- **Inspector = map:** the link budget at the probe equals `rssi(...)` within 0.001 dB.
- **Full field:** cell count, time in ms and coverage.
- **Map cell at probe:** the grid value is within 3 dB of the probe.
- **Optimizer:** time in ms, recommended satellite count and estimated coverage for each count.

It exits with status 1 if any check fails, so it can run in CI.

## 5. Performance budgets

| Work | Budget | Enforced by |
| :--- | :--- | :--- |
| Router-only optimization (demo) | < 600 ms in a debug build | `optimizerPerformanceBudget` |
| Router + 0–3 satellites, automatic (demo) | < 1,500 ms in a debug build | `optimizerPerformanceBudget` |
| Inspector vs map | < 0.001 dB | `linkBudgetMatchesFastPath`, runner |

Release builds are much faster (see [01 §7](01-architecture-and-vision.md#7-performance)). There is no automated memory or thermal test.

## 6. Device-only validation

The simulator and macOS cannot exercise these; check them on a LiDAR iPhone or iPad Pro before a release:

- [ ] Scan two or more rooms with **Next room**, including a closed door, an open door and a window; walls are cut at each.
- [ ] Mark the router during the scan; it appears locked at that spot.
- [ ] Scan two floors in one session; both floors appear with the right rooms.
- [ ] Background the app during a scan; **Save N rooms** keeps the captured rooms.
- [ ] Open AR after a scan; it relocalizes, the map lies on the floor aligned with the walls, and the live reading changes as you walk.
- [ ] Compare a few readings from AirPort Utility with the map, then calibrate; the error after is lower.
- [ ] Share a project by AirDrop to another device and open it there.
