# 10. Placement optimizer

How **Best placement** chooses positions for the router and mesh satellites, how its result is compared with the current layout, and how the tests keep it honest.

Code: `Sources/MeshPlannerCore/Engine/PlacementOptimizer.swift` (`PlacementOptimizer.optimize`) and `FloorplanViewModel.compare` in `Sources/MeshPlannerCore/ViewModels/FloorplanViewModel.swift`. The UI is `Sources/MeshPlannerUI/Sheets/OptimizerSheet.swift`.

---

## 1. What it optimizes

The goal is the number the user sees on the map: **the share of the home's floor area with signal at or above the coverage threshold** (`NetworkProfile.coverageThreshold`, −67 dBm by default) on the planning band. The planning band is the band selected in the request, or 5 GHz when the network supports it, otherwise 2.4 GHz.

The optimizer uses the same `PropagationModel` as the map, the inspector and the coverage summary, with first-order reflections on. It never has a model of its own.

Hard constraints:

| Constraint | Rule |
| :--- | :--- |
| Inside the home | The position is inside a room polygon on the floor being optimized (or inside the plan rectangle when there are no rooms). |
| Placeable | Not inside furniture or obstacle footprints, and at least `PlacementOptimizer.wallClearance` (0.15 m) from every opaque wall. Open doorways are not walls, so a node may stand in a doorway. |
| Backhaul | Every wireless satellite reaches the router through a chain of links of at least `minimumBackhaulRSSI` (−70 dBm) on the backhaul band. Wired satellites and wired nodes on other floors are always reachable. |
| Locks | A locked router (or **Keep the router where it is**) never moves. Locked satellites keep their positions. |

## 2. Request and result

```swift
let request = PlacementRequest(
    walls: project.walls, rooms: project.rooms, accessPoints: project.accessPoints,
    profile: project.profile, calibration: project.calibration,
    width: project.width, depth: project.depth, floor: 0,
    satellites: .automatic,      // or .exactly(n)
    lockRouter: false,           // defaults to the router's isLocked
    maxSatellites: 3
)
let proposal = PlacementOptimizer.optimize(request, token: cancellationToken, progress: { fraction in })
```

`PlacementProposal` holds the router position, the satellite positions, the recommended satellite count and `estimatedCoverageBySatelliteCount` (coverage for 0…N satellites). `optimize` returns `nil` when there is no active router, when there is nothing to evaluate, or when the token is cancelled.

## 3. Algorithm

### 3.1 Evaluation points

A uniform `FieldGrid` of about 0.34 m covers the plan (at most 960 points). Only cells inside the `InteriorMask` count, and each point is weighted by its room's importance (`RoomKind.importance`). Every other point (stride 2) forms a coarse set of up to 180 points used for fast screening. A small room that falls between grid centres gets fallback points so that it is never ignored.

### 3.2 Candidate pool

Up to 220 candidates, de-duplicated at 0.18 m:

1. Room label points and centroids, pushed away from walls.
2. Doorway sightlines: points 0.40, 0.75 and 1.25 m on both sides of every door and opening, and midpoints between nearby openings.
3. A 0.40 m interior grid, subsampled evenly when it does not fit.
4. A few extra points in rooms that are still uncovered by candidates.
5. **Last**, the current router and satellite positions (and their wall-pushed versions), into reserved slots.

The order matters. If the current positions were added first, they would shift the subsampling and de-duplication, so the pool and therefore the answer would change with the starting position. Adding them last keeps the shared pool identical for every start.

### 3.3 Path-loss tables

For every candidate, the optimizer computes `PropagationModel.effectiveLoss` (direct path plus reflections) to the coarse points. Promising candidates are upgraded to full rows over all evaluation points:

- the current positions;
- the top 24 coarse candidates, plus priority candidates (room centres, doorways) in the top 40;
- up to 12 spatially diverse candidates at least 1.25 m apart;
- the best 2 candidates of every room.

Other rows are computed lazily when the search needs them. Loss rows are independent of transmit power, so the same table serves the router and satellites with different powers. Work is spread with `DispatchQueue.concurrentPerform` and checks the cancellation token.

### 3.4 Score

Layouts are compared by `EvalMetrics`:

- **Coverage** is the percentage of evaluation points at or above the threshold, with the best server at each point (the strongest node wins; powers are not summed across nodes).
- **Score** breaks ties: coverage + 1.2 × mean soft utility (a logistic curve around the threshold) + 0.4 × importance-weighted utility + 0.15 × normalized mean signal, minus a backhaul penalty for weak or multi-hop satellite links.
- Two layouts whose coverage differs by more than 0.20 points are ranked by coverage; closer than that, by score.

When the planning band is 2.4 GHz but the network also has 5 GHz, a **5 GHz safeguard** blends in 5 GHz coverage (65 % planning band, 35 % 5 GHz) so that 2.4 GHz plans do not starve the faster band.

### 3.5 Router only

1. Score every upgraded candidate as the sole router.
2. Take the 6 best that are at least 1 m apart (`routerSeedCount`, `routerSeedSpacing`), plus the current position.
3. Refine each seed with a compass search: 8 directions at steps of 0.25, 0.10 and 0.05 m, screening probes on the coarse points first and confirming the best two on the full set.
4. Keep the best result. Moving away from a valid current position requires a real gain (more than 0.02 coverage points, or the same coverage and a better score).

Several seeds matter because the best spot is often a narrow ridge, such as standing in a doorway between two halves of the home. A single seed or a coarse grid stops in a local optimum.

### 3.6 Satellites

For k = 1 … max satellites, the best (k − 1) layout is extended and four kinds of seeds are refined:

| Seed | Idea |
| :--- | :--- |
| A, greedy | Add the best connected candidate to the previous layout. |
| B, existing | Start from the user's current satellites, filling up with greedy additions. |
| C, wing | Put the router in a different wing (at least 2.5 m away) and add satellites greedily. |
| D, weakest room | Put the new satellite in the room with the lowest coverage. |

Each seed goes through coordinate descent: every movable node in turn moves to its best connected candidate, for up to two passes. Two guards follow:

- **Keep the current layout** when the count equals the existing satellites and the new layout is not strictly better.
- **Monotonicity**: k satellites never report less coverage than k − 1.

### 3.7 Choosing the count

With `.exactly(n)`, the result has n satellites, or fewer when no further satellite can stay connected. With `.automatic`, the count is the first that reaches 90 % coverage, or the first where one more satellite adds less than 3 points. The chosen layout gets a final compass polish (0.18 m and 0.05 m steps) and is kept only if it is not worse.

## 4. Comparing with the current layout

`FloorplanViewModel.compare(project:proposal:floor:)` produces the numbers in the sheet:

- **Same grid as the map.** Before and After are computed with `SignalFieldGenerator` on `FieldGrid.covering(targetCell: 0.1, maxCells: 30_000)`, the grid of the map's final render, so **Before** always equals the percentage on the map.
- **Never worse.** If After is below Before, the sheet says the current placement is already the best and nothing is applied.
- **No trivial moves.** With the same number of satellites, a proposal must gain at least `minimumCoverageGain` (1.0 point) of coverage, or raise the median signal by `minimumMedianGainDb` (3 dB). Smaller changes are within the noise of the grids and would make **Optimize** suggest a new spot on every run.

Applying uses `FloorplanViewModel.applyingProposal`, which moves the router, keeps satellite identities (closest match by backhaul type, locked ones fixed), adds new satellites and removes surplus ones. The change is undoable.

## 5. Accuracy and verification

References were computed once by brute force: every placeable point on a 0.05 m lattice was scored, and the best 600 were re-scored on the map's 0.1 m grid. From six different starting positions the optimizer reaches:

| Fixture | Best possible | Optimizer (every start) |
| :--- | :---: | :---: |
| Demo apartment | 96.60 % | 95.89 % |
| Demo, all partitions brick | 87.33 % | 86.60 % |
| Demo, doors closed | 87.59 % | 87.59 % |
| Demo mirrored in Y | 96.60 % | 95.90 % |
| Brick partitions mirrored in Y | 87.33 % | 86.85 % |

One satellite with the router locked in the weak corner reaches 98.04 % against a brute-force 98.14 %. Router-only optimization takes about 30–40 ms in a release build on an M-series Mac and about 350 ms in a debug test run.

The tests that protect this behaviour are in `Tests/MeshPlannerCoreTests/OptimizerNeverWorseTests.swift`, and the UI flow is covered by `testRouterOnlyOptimizeMatchesMapAndIsAlreadyBestAfterApply` in `Tests/MeshPlannerUITests`. See [08 Testing and benchmarks](08-testing-and-benchmarking.md).

## 6. Known limits

- Positions are evaluated on a 0.34 m grid, so the result can be up to about 1 point below the true optimum on the map's finer grid.
- The optimizer works on one floor at a time. Nodes on other floors are fixed and only add signal.
- Wall clearance is 0.15 m in the optimizer and 0.05 m when the user drags a node, so a hand-placed node can sit closer to a wall than the optimizer would put it.
