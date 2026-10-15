# 07. Storage, sharing and export

How projects are saved, backed up, shared, imported and exported. There is no account and no cloud sync; files move between devices only when the user shares them.

Code: `Sources/MeshPlannerCore/Serialization/` (`ProjectStore.swift`, `ProjectValidation.swift`, `SignalDataExporter.swift`, `ExportFilename.swift`, `SignalDebugLogger.swift`), `Sources/MeshPlannerUI/Style/ProjectDocument.swift` and `Sources/MeshPlannerUI/Report/ReportRenderer.swift`.

---

## 1. On disk

```
Documents/
└── Projects/                       visible in Files › On My iPhone › Mesh Planner
    ├── <id>.signalsim              the project (JSON)
    └── .<id>.worldmap              ARWorldMap for AR (hidden, never shared)
Application Support/
└── Backups/<id>/<unix-time>.signalsim   up to 5 per project, at least 10 min apart
```

- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` make the folder visible in Files. Builds before the rename used `Documents/Projetos`; it is renamed (or merged) into `Projects` on first launch.
- An even older build kept a single scan in `Documents/current_scan.json`. It is converted into a project once and renamed to `current_scan.migrated.json`.
- Deleting a project removes its file, world map and backups.

## 2. Project file (`.signalsim`)

JSON with sorted keys and ISO 8601 dates. `FloorplanProject.currentSchemaVersion` is **3**.

| Key | Contents |
| :--- | :--- |
| `schemaVersion`, `id`, `name`, `createdAt`, `updatedAt`, `isDemo` | Identity and dates. |
| `width`, `depth`, `floorCount` | Plan size in metres; floors (1–32). |
| `walls` | `RFWallSegment`: endpoints, floor, material (with its losses), thickness, height, kind, `groupId`, active, exterior and `isMaterialAuto` flags. |
| `accessPoints` | Router and satellites: position, floor, transmit power, satellite, active and locked flags, backhaul type. |
| `rooms` | Name, kind, polygon, floor. |
| `furniture` | Objects shown on the plan: category, position, size, yaw, floor. |
| `profile` | `NetworkProfile`: Wi-Fi standard (which sets the bands), channel width per band, client streams, dedicated backhaul radio and band, internet plan, construction, coverage threshold, palette, floor height. |
| `calibration` | Path-loss exponent, wall-loss scale, offset, RMS before/after, sample count. |
| `measurements` | Calibration readings: position, floor, band, RSSI, date. |
| `probe`, `probeFloor`, `selectedBand` | Where the pin is and which band is shown. |
| `worldAlignment` | Rotation, offset and floor elevations for AR ([06](06-ar-floor-overlay.md#alignment-math)). |

Missing keys get defaults, so older and hand-written files still load. Projects below schema 3 are repaired once on load ([02 §6](02-lidar-capture-roomplan.md#6-older-projects)) and saved back with their original `updatedAt`.

## 3. Saving

- Every change goes through the view model, which marks the project dirty and saves it **800 ms** after the last change. A drag saves once, when it ends.
- Pending changes are flushed before opening another project, when closing the map and when the app goes to the background (inside a background task).
- Writes are atomic. If a save fails, the error alert offers **Retry saving**.
- After each save a backup is written if the newest one is older than 10 minutes; only the five newest are kept.
- The demo project is never saved.

## 4. Loading and recovery

1. Read `<id>.signalsim` (at most 20 MB), check that its `id` matches the file name, repair if needed and validate.
2. If that fails, try the backups from newest to oldest. The first readable one is restored as the main file.
3. If none works, the project is not listed and opening it shows: "This project is damaged, uses an unsupported version, or exceeds supported geometry limits. Try another copy or backup."

### Validation

`FloorplanProject.validate()` runs on every decode, import and save, before any geometry work:

| Check | Limit |
| :--- | :--- |
| Schema version | 1–3 |
| `id` | Non-empty, ≤ 256 characters, no `/`, `\`, `.` or `..` |
| Plan size | 0 < width, depth ≤ 1,000 m |
| Floors | 1–32; every element's floor must exist |
| Counts | walls ≤ 10,000, rooms ≤ 512 (≤ 2,048 points each), access points ≤ 64, furniture ≤ 5,000, measurements ≤ 10,000 |
| IDs | Unique per collection |
| Numbers | Finite and within sane bounds (coordinates ≤ 10 km, losses ≤ 1,000 dB, client streams 1–8, positive floor height and path-loss exponent) |

## 5. Sharing a project

**More › Share project** shares a `.signalsim` copy named after the project (unsafe characters replaced, at most 120 characters) through the system share sheet: AirDrop, Mail, Messages, Files and so on. The world map is not included.

The app declares the type in `project.yml`:

| Field | Value |
| :--- | :--- |
| UTI | `com.silviogodinho.signal.project` (conforms to `public.json`, `public.data`) |
| Extension, MIME type | `signalsim`, `application/x-signalsim` |
| Handler rank | Owner |

## 6. Importing

From the home screen's import button (accepts `.signalsim` and `.json`) or by opening a file from another app:

1. A file that is already in `Projects` simply opens.
2. Otherwise the file is read (at most 20 MB) and decoded as, in order:
   - a **project** (any schema version, at least one wall), repaired and validated;
   - a **legacy scan** (the old `current_scan.json` format);
   - a **web floorplan document** (version 1.0 or 2.0, ≤ 1,000 materials, ≤ 10,000 walls, ≤ 64 access points).
3. The result is saved as a **new project** with a new id (importing the same file twice gives two projects), and opened with the toast "Project imported."

Imported projects have no world map, so AR is unavailable for them.

## 7. Web floorplan JSON

**More › Advanced › Export to the web simulator** shares `<name>-web.json` in the `SignalFloorplanDocument` format, version 2.0:

```json
{
  "version": "2.0",
  "name": "Demo apartment",
  "timestamp": "2026-10-15T12:00:00Z",
  "dimensions": { "width": 14, "depth": 10, "wallHeight": 2.7 },
  "materials": [{ "id": "drywall", "name": "Drywall", "crossingLoss": [3, 4, 5], "reflectionLoss": 10, "color": "#…" }],
  "walls": [{ "id": "…", "name": "…", "p1": [0.3, 0.3], "p2": [5.3, 0.3], "materialId": "drywall",
              "thickness": 0.1, "height": 2.7, "active": true, "objId": 0 }],
  "accessPoints": [{ "id": "…", "name": "Router", "x": 3.2, "z": 4.1, "txPower": 20, "isSatellite": false }]
}
```

- Only the ground floor is exported. Rooms, furniture, profile, calibration and alignment are not part of the format.
- On import, materials in the document override the built-in ones with the same id; unknown material ids fall back to drywall; every wall is marked as a manual material. The document has no rooms, so the whole plan rectangle counts for coverage until the project is scanned.
- The format comes from a separate web simulator. That simulator is **not** in this repository (the `web/wifi.html` path mentioned in `SignalDataExporter.swift` does not exist here).

## 8. PDF report

**More › PDF report** (available once the heatmap is ready) renders one A4 page with `ImageRenderer` in light mode and a print palette, then opens a share sheet titled "Report ready". The file is `Wi-Fi report - <name>.pdf`.

The page contains:

- title, project name and date;
- **Summary:** floor and band, coverage of this floor, area and room count, typical signal, calibration sample count when calibrated;
- **Equipment:** Wi-Fi standard, satellite count, internet plan;
- the plan with heatmap, walls, backhaul lines and nodes (no pin, rays or proposal), and the legend;
- **By room:** coverage and median signal for up to 12 rooms;
- **Recommendations:** rooms below 80 % coverage (first three named), a note about weak satellite backhaul, or a confirmation that every room is covered;
- a footnote that values are model estimates.

## 9. Diagnostics

**More › Advanced › Diagnostics** shows the full project JSON and the last 300 entries of `SignalDebugLogger` (in memory only, cleared when the app quits), with **Copy**. It is meant to be pasted into a support email. Nothing is sent automatically.
