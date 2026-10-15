# Mesh Planner documentation

Technical documentation for Mesh Planner, written against the current code. When code and docs disagree, the code wins; fix the doc in the same change.

| Doc | Read it when you need to know |
| :--- | :--- |
| [01 Architecture](01-architecture-and-vision.md) | What the app does, the targets and folders, data flow, the consistency rules, concurrency, performance and privacy. |
| [02 LiDAR capture and RoomPlan](02-lidar-capture-roomplan.md) | How a scan becomes a floor plan: capture, extraction, alignment, corner welding, rooms, openings, obstacles, router marker. |
| [03 RF propagation engine](03-rf-propagation-engine.md) | The signal model and its formulas, reflections, the public API, signal field and coverage, signal scale, link rate, backhaul and calibration. |
| [04 Materials and semantics](04-materials-and-semantics.md) | The material catalog and losses, wall kinds, automatic classification and editing materials. |
| [05 Screens and interaction](05-interactive-ui-ux.md) | Every screen, gesture, sheet and menu item, undo and accessibility. |
| [06 AR walkthrough](06-ar-floor-overlay.md) | Relocalization, placing the heatmap on the floor, the live reading and AR limits. |
| [07 Storage, sharing and export](07-export-sync-and-sharing.md) | File layout, the `.signalsim` format, saving and backups, validation, import, web JSON, PDF and diagnostics. |
| [08 Testing and benchmarks](08-testing-and-benchmarking.md) | Commands, every test suite, UI test hooks, performance budgets and the device checklist. |
| [09 Review and plan](09-review-and-plan.md) | The technical review: problems found, the fixes made and the decisions behind them. |
| [10 Placement optimizer](10-placement-optimizer.md) | How "Optimize placement" searches, scores and compares router and satellite positions. |
| [appstore/metadata.md](appstore/metadata.md) | App Store name, description, keywords and review notes. |

Build, run and release instructions are in the [repository README](../README.md); implementation status is in [TRACKING.md](../TRACKING.md).

## Where to start

- **New to the code:** 01, then 03 and 05.
- **Changing the signal model:** 03 and 04, then the references in 08 and 10. Every number on screen comes from `PropagationModel`, so a change shows up everywhere.
- **Changing the scan pipeline:** 02 and 04; validate on a LiDAR device (08 §6).
- **Changing the file format:** 07; bump `FloorplanProject.currentSchemaVersion` only with a repair step in `ProjectRepair` and a test.
