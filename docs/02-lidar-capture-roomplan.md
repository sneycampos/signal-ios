# 02. LiDAR capture and RoomPlan pipeline

How a walk through the home becomes an RF-ready floor plan: capture with RoomPlan, extraction into plain data, conversion (alignment, corner closing, openings, obstacles, rooms) and project creation.

Code:

| Stage | File |
| :--- | :--- |
| Device checks, capture session, room-by-room flow | `Sources/MeshPlannerUI/Scan/ScanController.swift` |
| Scan screen | `Sources/MeshPlannerUI/Scan/RoomScanView.swift` |
| RoomPlan → raw types (the only RoomPlan-dependent conversion) | `Sources/MeshPlannerUI/Scan/RoomPlanExtraction.swift` |
| Raw types → floor plan | `Sources/MeshPlannerCore/Converters/RoomPlanConverter.swift` |
| Room completion and repair of older projects | `Sources/MeshPlannerCore/Geometry/RoomRegionDetector.swift`, `Sources/MeshPlannerCore/Converters/ProjectRepair.swift` |
| Project creation | `FloorplanViewModel.createProject(from:worldMap:)` |

The converter lives in `MeshPlannerCore` and works on plain structs, so it is tested on macOS without RoomPlan or a device.

---

## 1. Before scanning

`ScanAvailability.current` decides what the home screen offers:

| State | Home screen |
| :--- | :--- |
| Available | **Scan my home** (or **New scan** when projects exist). |
| Camera denied | "Camera access is turned off." with **Open Settings**. |
| No LiDAR (`RoomCaptureSession.isSupported == false`) | No scan button; a note explains that scanning needs an iPhone or iPad Pro with LiDAR and that the demo and import still work. |

Availability is re-checked when the home screen appears and when the app becomes active. Starting a scan asks for camera permission if needed, closes any open project and presents the scan full screen.

## 2. Capturing room by room

`ScanController` (`@MainActor @Observable`) runs a `RoomCaptureSession` on **one shared `ARSession`** for the whole home. Every room is therefore in the same world coordinates, and the final `ARWorldMap` can relocalize the AR walkthrough later. RoomPlan's own post-scan preview is turned off; the app shows its own UI.

### Scan screen

- **Top:** cancel button and a "Room N" label.
- **Bottom panel:** live counters (walls, doors, windows, objects; openings count as doors) and the hint "Walk the room pointing at walls, doors, and windows. Open doors that usually stay open."
- **I'm next to the router:** records the current camera position as the router position (tap again to move it). The button turns green: "Router marked here".
- **Next room** (needs at least one wall): stops the capture for this room but keeps the `ARSession` running, builds the room, then starts the next one.
- **Done:** saves the `ARWorldMap`, stops the capture, builds the last room and the whole home.
- While a room is processed, an overlay shows "Processing the room…" or "Building the home plan…" and the controls are disabled.

### Building and merging

1. Each room is built with `RoomBuilder(options: [.beautifyObjects])`.
2. With several rooms, `StructureBuilder` merges them into one `CapturedStructure`. If merging fails, the rooms are concatenated as they are (they already share coordinates).
3. Floors come from RoomPlan's `story` values. There is no "new floor" button: walk up the stairs and keep scanning in the same session.

### When something goes wrong

| Situation | What happens |
| :--- | :--- |
| A room cannot be built | Alert "Room couldn't be processed": **Rescan room**, or **Save N rooms** when finishing with rooms already captured. |
| The session stops with an error or the app goes to the background | Alert "Couldn't finish" with the reason; **Save N rooms** keeps what was captured, otherwise the scan closes. |
| Cancel after capturing something | "Discard this scan?" (**Discard** / **Keep scanning**). |
| No walls at all | "No walls were detected. Point the camera slowly at walls and corners, with good lighting." |

Saving captured rooms after an error does not include a world map, so AR is unavailable for that project until it is scanned again.

## 3. Extraction (`RoomPlanExtraction`)

RoomPlan objects are turned into platform-independent structs (`RoomPlanCapture`). Plan coordinates are world **X → plan x** and world **Z → plan y**; world Y is height. Units are metres.

| RoomPlan | Raw data |
| :--- | :--- |
| Wall, door, window, opening (`Surface`) | Endpoints `centre ∓ direction · length/2` from the transform, height, thickness (≥ 0.08 m), `parentIdentifier`, `isOpen` for doors, story. |
| Object | Centre, footprint size, yaw, category, story. |
| Floor | Polygon corners in world space (or a rectangle from the dimensions), elevation, story. |
| Section | Label (living room, kitchen, bedroom, bathroom, dining room…), centre, story. |
| Router marker | Camera position (x, z) and story when the button was tapped. |

## 4. Conversion (`RoomPlanConverter.convert`)

### 4.1 Floors and orientation

- Distinct `story` values, sorted, become floors 0, 1, 2….
- The plan is rotated so that the dominant wall direction (length-weighted, modulo 90°) lines up with the axes.
- Walls within 6° of an axis are snapped exactly onto it.

### 4.2 Normalization

The plan is shifted so that everything starts 0.3 m from the origin, and the plan size is the extent plus 0.3 m on each side (at least 2 × 2 m). The rotation, offset, floor height and per-floor elevations are kept as `WorldAlignment`, which maps plan points back to the world for AR.

### 4.3 Closing corners

On each floor:

1. Endpoints of different walls closer than 0.12 m are welded together, at the lines' intersection when that is within 0.24 m.
2. An endpoint up to 0.12 m from the middle of another wall is snapped onto it (T-junctions).
3. Walls shorter than 2 cm are dropped.

There is no separate step that removes duplicate walls between rooms; `StructureBuilder` merges them when it succeeds.

### 4.4 Rooms

1. RoomPlan floor polygons with an area of at least 0.5 m² become rooms. Their kind comes from the section whose centre falls inside (living room, kitchen, bedroom, bathroom, dining room; otherwise "Room").
2. `RoomRegionDetector` fills gaps: on a 0.1 m grid it blocks cells within 0.12 m of walls, doors and windows, flood-fills the outside from the border and keeps each enclosed region of at least 1.2 m² as a room. Regions already mostly covered by a RoomPlan room are skipped.
3. As a last resort, each floor gets the convex hull of its walls.
4. Names come from the kind ("Bedroom 1", "Bedroom 2"; a kind that appears once has no number).

### 4.5 Doors, windows and openings

Each opening is cut out of its parent wall: the wall found by `parentIdentifier`, otherwise the nearest wall on the same floor that is parallel (within about 14°), overlaps it and is less than 0.3 m away. The wall is split around the gap and the gap gets the opening's material ([04 §3.3](04-materials-and-semantics.md#33-doors-windows-and-openings)). This is what lets signal pass through open doors.

### 4.6 Materials

Exterior and interior walls are told apart from the rooms on each side and get the construction profile's materials (masonry by default). Wall thickness comes from the material, not from the scan. See [04 Materials](04-materials-and-semantics.md).

### 4.7 Objects

Every object is shown as furniture. Objects that affect Wi-Fi (appliances, cabinets, bathtubs, sinks, toilets, fireplaces, TVs) also become four-sided obstacle boxes, rotated by their yaw, with one `groupId` per object, so a ray pays for each object once.

### 4.8 Router position

The marked position is converted to plan coordinates, moved inside the nearest room if it fell outside, and pushed 5 cm off walls. The router is created **locked** when it was marked, so the optimizer keeps it there unless the user unlocks it. Without a marker the router starts in the largest room and the map opens in "place the router" mode.

## 5. Project creation

`createProject(from:worldMap:)` runs the conversion off the main actor, then creates a project named "Scan of ‹date›" with the masonry profile, the router, the probe near the first room, the floor count and the `WorldAlignment`. It saves the project and the world map (`.<id>.worldmap` next to the project file) and opens the equipment setup sheet.

## 6. Older projects

Projects saved before schema 3 are repaired once when loaded or imported (`ProjectRepair.upgradeIfNeeded`): doors drawn over walls are cut in, old Portuguese names are replaced, rooms are rebuilt with `RoomRegionDetector`, and automatic materials are reclassified. Demo projects are never repaired or saved.

## 7. Devices without LiDAR

There is no manual wall-drawing mode. Without LiDAR the user can open the built-in **demo apartment** (14 × 10 m, seven rooms) or **import** a `.signalsim` or JSON project. See [07 Export and sharing](07-export-sync-and-sharing.md).

## 8. Testing the pipeline

- `RoomPlanConverterTests` covers alignment, welding, opening cuts, obstacles, rooms and floors with synthetic captures.
- `RealScanTests` covers repair of a synthetic legacy project.
- The UI test `testFakeScanFailureWhileWarningOrCancelDialogOpen` drives the scan screen's error paths with the `-uitest-fake-scan-failure` launch argument, which fakes a capture without a camera.
- The capture itself (RoomPlan, ARKit, the world map) can only be validated on a LiDAR device.
