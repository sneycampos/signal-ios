# 09. Technical review and improvement plan (September 2026)

> A full review of the code made on 26 September 2026 (MeshPlannerCore, MeshPlannerUI, SignalApp, tests, docs and the Xcode project), followed by the plan that was then carried out. Every item in this document is implemented. It is kept as the record of **why** the app works the way it does; for how it works today, read docs 01–08 and 10.
>
> Product goal: scan whole homes with LiDAR and find the best positions for the router and mesh satellites, with the highest possible coverage. App Store work (privacy manifest, launch screen, metadata) was out of scope for this plan.

Severity: **P0** gives wrong results or blocks the goal; **P1** hurts the experience or trust a lot; **P2** quality and maintenance; **P3** polish.

---

## 1. How the review was verified

- Read all Swift code (about 6,000 lines), the Metal shader, the docs, `project.yml` and `Package.swift`.
- Built for the iOS Simulator with no code warnings.
- 10 XCTests passed. `SignalTestRunner` passed 15 of 16 checks: check 14 (export and re-import JSON) failed, although `TRACKING.md` claimed 16/16.
- Isolated scripts confirmed the behaviours and measured performance (release build, Mac):
  - In the demo's default state the direct path to the probe was −103.2 dBm, but the inspector showed −54.6 dBm because of a reflection through the bedroom door.
  - Coverage of the same state came out as 76.8 % (heatmap), 79.9 % (0.5 m grid) and 92.6 % (with reflections).
  - Two metal cabinets on the same ray counted 35 dB instead of about 70.
  - A ray through the joint of two concrete walls passed with 0 dB, and so did a router standing on a wall.
  - Heatmap 112 × 80: 0.56 ms (demo) and 2.4 ms (160 segments). Each drag event emitted 13 `objectWillChange`; each band switch, 15.
  - Optimizer: 36 ms on the demo; 864 ms on a 24 × 16 m home while improving only from 55.9 % to 56.1 %.
  - `saveScan`: 2.6 ms and 83 KB per save, a new backup on every save, never cleaned up.
  - After `deleteSavedScan()`, `loadLatestScan()` restored the scan from the backup.

## 2. Findings and fixes

### 2.1 Simulation and scan accuracy

| # | Sev. | Problem | Fix |
|---|---|---|---|
| A1 | P0 | RoomPlan doors, windows and openings were added on top of walls without cutting them. Signal could not pass through doors; `opening` fell into `default` and became a wall; windows added glass plus wall. | Cut the parent wall over each opening (by `parentIdentifier` or geometric overlap) and fill the gap with the opening's material (open: 0 dB, closed: wooden door, window: glass). |
| A2 | P0 | The converter ignored RoomPlan objects; rotation was ignored; `objId` was a category bitmask, not an instance. | Relevant objects become rotated boxes with a per-instance ID; the engine de-duplicates crossings per instance. |
| A3 | P0 | One room per session, no whole home and no floors; room polygons from a greedy heuristic. | Multi-room scan in the same `ARSession` merged with `StructureBuilder`; RoomPlan `floors`, `sections` and `story`; floors in the engine with slab loss. |
| A4 | P0 | Coverage computed over the bounding rectangle, including margins and outdoor area. | Interior mask from the floor polygons, used by heatmap, coverage, optimizer and probe. |
| A5 | P0 | Heatmap and coverage used only the direct path while the inspector used reflections; three different coverage grids. | One signal field (direct + reflections) used by the map, coverage, badges, probe and optimizer. |
| A6 | P1 | Material classification: every wall touching the perimeter became brick; the thickness rule never fired; windows always Low-E; interior always drywall. | Exterior walls detected from the outside of the room polygons; construction profile (masonry, drywall, concrete); ordinary glass by default; larger catalog. |
| A7 | P1 | Relative epsilon in intersections: leaks at wall joints and no loss for an AP standing on a wall. | Absolute epsilon in metres, inclusive endpoints with de-duplication of coincident crossings, APs pushed off walls and objects. |
| A8 | P1 | Backhaul modelled as −10 dB of power; always 5 GHz; no cable, no chaining. | Backhaul as a throughput limit; backhaul tree (router or another satellite); Ethernet option; configurable band; backhaul line on the map. |
| A9 | P1 | Fixed −95 dBm noise for every channel width; "speed" was the PHY rate; incorrect "ITU-R P.1238" label. | Noise by channel width; MCS table by Wi-Fi standard, width and streams; real throughput limited by backhaul and the internet plan; "multi-wall model" label. |
| A10 | P2 | Three implementations of the physics (engine, generator, Metal shader) that already disagreed. | One core; the dead Metal renderer and the duplicate `.metal` file removed. |
| A11 | P3 | Reflection leg 2 had no `continue` after the 22 dB cut. | Fixed in the new core. |
| A12 | P2 | Shadows with perfectly sharp edges (direct path only). | Reflections in the field; contour lines at the thresholds. |

### 2.2 Finding the best spot

| # | Sev. | Problem | Fix |
|---|---|---|---|
| B1 | P0 | The optimizer moved only the router and ignored satellites and backhaul. | Joint router + N satellites optimization with the backhaul constraint and a recommended node count. |
| B2 | P0 | Positions inside objects and outside the home were accepted. | Candidates only indoors, outside objects and at a minimum distance from walls. |
| B3 | P1 | Binary objective, direct path only, selected band only. | Continuous objective weighted by room on the limiting band; final check with the full model. |
| B4 | P1 | Result applied without preview or undo; summary not in the app's language; not saved; no cancel; two different buttons. | One sheet with options, progress, cancel, before/after preview, Apply/Discard and Undo. |
| B5 | P1 | No real constraints (fiber outlet, socket). | "Keep the router where it is" and the router position marked during the scan. |

The optimizer was redesigned again in October 2026; see [10 Placement optimizer](10-placement-optimizer.md).

### 2.3 Colours and thresholds

| # | Sev. | Problem | Fix |
|---|---|---|---|
| C1 | P1 | Six different scales (CPU heatmap, Metal, legend, `SignalGrade`, `RoomZone`, probe radius). | One `SignalScale` type with thresholds, colours and texts, used across the app. |
| C2 | P1 | Red-to-green palette poor for colour blindness; misleading "Gigabit"/"Ultra 4K" labels. | Accessible alternative palette; contour lines at −67/−75 dBm; labels based on what the user can do. |

### 2.4 Broken or unreachable controls

| # | Sev. | Problem | Fix |
|---|---|---|---|
| D1 | P0 | Editing a wall's material was impossible (`selectedWallId` was never set). | Tap a wall on the 2D map; editor with bulk apply. |
| D2 | P0 | Satellites could not be removed. | AP editor with remove, rename, power, backhaul and lock. |
| D3 | P0 | Deleting a scan did not work (restored from backup; the card stayed). | Multiple projects; delete removes the project and its backups, with confirmation. |
| D4 | P1 | "Open saved map" opened the demo if it had been viewed before. | Project list; demo kept separate. |
| D5 | P1 | Simulated AR mode. | Real AR with the `ARWorldMap` saved at the end of the scan, heatmap on the floor and live probe. |
| D6 | P1 | Dragging failed in 3D (perspective only in drawing) and `draggingApId` stuck on cancel. | Editing only in 2D (3D is view-only); `@GestureState`. |
| D7 | P1 | Sharing sent a String; no import; incompatible export/import formats; exporter fixed at 14 × 10 m; open doors became drywall on import. | `.signalsim` file (Transferable + UTType), import through `fileImporter`/`onOpenURL`, one project format; web exporter fixed. |
| D8 | P1 | "New scan" replaced the only project; a race on cancel could overwrite the map. | Each scan creates a project; scan controller holds a direct reference to the session. |
| D9 | P1 | No LiDAR or camera-permission check. | `RoomCaptureSession.isSupported` and camera status checked before scanning. |
| D10 | P2 | Promised backups in the Files app did not exist. | File-sharing keys in `project.yml`. |
| D11 | P3 | "Reflections" toggle only affected the probe; dead `showZoneBadges`; fake progress. | Removed or fixed. |

### 2.5 Performance

| # | Sev. | Problem | Fix |
|---|---|---|---|
| E1 | P1 | SwiftUI invalidation: `ObservableObject` with about 45 `@Published`; zoom/pan in the view model; element-by-element mutation. | `@Observable`, local gesture state, single assignments. |
| E2 | P2 | Work in `body`: polygons recomputed, disk read on the home screen. | Derived values cached in the model. |
| E3 | P1 | Synchronous save at the end of every drag, unbounded backups. | Background persistence actor, debounce, 5 backups kept, compact JSON. |
| E4 | P2 | Optimizer without cancel, allocations in the hot loop, no parallelism. | Candidates × points matrix with an allocation-free fast path and `concurrentPerform`. |
| E5 | P2 | Synchronous launch; logger opened the file on every line. | Asynchronous loading; `os.Logger` with buffering. |

### 2.6 UI/UX, accessibility and language

| # | Sev. | Problem | Fix |
|---|---|---|---|
| F1 | P1 | Missing flow: mark the router, configure equipment, per-room result. | "I'm next to the router" button during the scan; equipment sheet; per-room summary. |
| F2 | P1 | Fixed paddings; sheet with estimated height; wrapping buttons; tilted HUD in 3D. | `NavigationStack` + `safeAreaInset`; HUD outside the 3D container. |
| F3 | P1 | Targets under 44 pt, fixed fonts, no accessibility labels, canvas invisible to VoiceOver, no Reduce Motion, excessive haptics. | Text styles, 44 pt targets, accessibility labels and actions, `accessibilityReduceMotion`, `sensoryFeedback` only on confirmations. |
| F4 | P1 | Mixed languages; development region `en`; numbers with a decimal point. | Superseded: on 27 September 2026 the app became English-only, with no translations. |
| F5 | P2 | Jargon (RSSI, SNR, FSPL), coordinates in the header, wall names with old materials, diagnostics in the main UI, overstated copy. | Plain language, technical details under "Details", diagnostics in a menu, honest copy. |
| F6 | P3 | Deprecated APIs; `ForEach` by index; two drag indicators. | Updated. |

### 2.7 Architecture and tests

| # | Sev. | Problem | Fix |
|---|---|---|---|
| G1 | P2 | An 880-line view model mixing everything. | Pure core (engine, field, optimizer, converter), project store, orchestrating view model. |
| G2 | P2 | Command flags passed through `updateUIView`. | Scan controller. |
| G3 | P2 | Magic numbers; `crossingLoss` indexed by position. | Explicit types; safe, backward-compatible decoding. |
| G4 | P2 | Singletons; tests wrote to the real Documents folder. | Injectable directory. |
| G5 | P2 | `Package.swift` without strict concurrency; `.pbxproj` out of sync with `project.yml`; Swift 6 off. | Swift 6 in both; project generated from `project.yml`. |
| G6 | P2 | Empty tests (13, 15, 16) and none where the bugs were. | Tests for converter, mask, optimizer, persistence, scale, rate and sharing. |
| G7 | P2 | Docs claimed features that did not exist. | README, TRACKING and docs updated. |

## 3. Implementation decisions

- **Propagation model:** multi-wall (free space plus per-wall loss with an oblique factor capped at 2×) with one-bounce specular reflections. Between floors: 3D distance, walls of the receiver's floor and a slab loss per floor. Current constants are in [03 RF propagation engine](03-rf-propagation-engine.md).
- **Best server:** a client associates with the AP that gives the strongest signal; powers from different APs are never summed.
- **Default signal scale:** excellent ≥ −55, good ≥ −67 (coverage threshold, configurable), fair ≥ −75, weak ≥ −85, no signal < −85 dBm.
- **Rate and throughput:** noise = −174 + 10·log10(width) + 7 dB; MCS from SNR; real throughput ≈ 60 % of the PHY rate, limited by backhaul and the internet plan.
- **Language:** English only, no translations.
- **File format:** `.signalsim` = the project's JSON, with migration of older files.
- **3D:** view only; editing happens in 2D.

## 4. Second round (27 September 2026)

- **Black rooms:** `RoomRegionDetector` finds regions enclosed by walls (doors and windows count as barriers; the outside is flood-filled from the border). It completes RoomPlan floors and rebuilds rooms of older projects.
- **Repair of older projects (schema 3):** `ProjectRepair` cuts doors that overlap walls, reclassifies materials (exterior/interior), replaces the old Low-E window glass with ordinary glass and cleans up wall names. Validated with a synthetic legacy project derived from the demo apartment (`RealScanTests`): from 3 broken polygons to 8 rooms, all with a map.
- **Signal colours:** scale extended to −35 dBm, 0.6 m visual smoothing inside each room, distance exponent 2.5 and a 3 dB device margin when uncalibrated.
- **Redesigned UI** from generated prototypes (map, home screen, point details): full-screen map, floating header and band picker, controls rail, summary card, signal meter, thumbnails with a coverage ring. Tested in the simulator with real taps: open a project, switch band, drag the router, undo, optimize/apply, add a satellite, 3D.

## 5. Where each fix lives

| Area | File |
|---|---|
| Single engine, tolerances, de-duplication, reflections, floors | `Sources/MeshPlannerCore/Engine/RFPropagationEngine.swift` |
| Signal field, mask, per-room coverage, contours, heatmap | `Sources/MeshPlannerCore/Engine/SignalField.swift` |
| Rate and throughput | `Sources/MeshPlannerCore/Engine/LinkRateModel.swift` |
| Backhaul | `Sources/MeshPlannerCore/Engine/BackhaulPlanner.swift` |
| Optimizer | `Sources/MeshPlannerCore/Engine/PlacementOptimizer.swift` |
| Calibration | `Sources/MeshPlannerCore/Engine/Calibrator.swift` |
| RoomPlan converter | `Sources/MeshPlannerCore/Converters/RoomPlanConverter.swift` |
| Signal scale | `Sources/MeshPlannerCore/Models/SignalScale.swift` |
| Projects and persistence | `Sources/MeshPlannerCore/Models/FloorplanProject.swift`, `Sources/MeshPlannerCore/Serialization/ProjectStore.swift` |
| View model | `Sources/MeshPlannerCore/ViewModels/FloorplanViewModel.swift` |
| Multi-room scan | `Sources/MeshPlannerUI/Scan/` |
| Map, legend, gestures, accessibility | `Sources/MeshPlannerUI/Map/` |
| Sheets (inspector, equipment, optimizer, calibration) | `Sources/MeshPlannerUI/Sheets/` |
| AR | `Sources/MeshPlannerUI/AR/ARWalkthroughView.swift` |
| PDF report | `Sources/MeshPlannerUI/Report/ReportRenderer.swift` |
