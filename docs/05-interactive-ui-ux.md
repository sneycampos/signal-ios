# 05. Screens and interaction

What the user sees and touches: the home screen, the map, the inspector and the sheets. The interface is SwiftUI in dark mode with floating glass panels, portrait on iPhone, and any orientation on iPad.

Code: `Sources/MeshPlannerUI/` (`AppRootView.swift`, `Home/`, `Map/`, `Sheets/`), with the logic in `FloorplanViewModel`.

---

## 1. Navigation

```
Home (project list)
 ├── Scan my home ──▶ Scan (full screen, see 02) ──▶ Map + Equipment sheet
 ├── Open demo apartment ──▶ Map
 ├── Import (toolbar) ──▶ Files picker (.signalsim or .json) ──▶ Map
 └── project row ──▶ Map
        ├── Inspector sheet (point, wall, router, satellite, room)
        ├── Best placement sheet
        ├── Calibrate sheet
        ├── Equipment sheet
        ├── AR walkthrough (full screen, see 06)
        └── Share, PDF report, rename, web export, diagnostics
```

Opening a `.signalsim` file from another app (Files, Mail, AirDrop) imports it directly (`onOpenURL`). Errors from any step appear in one "Something went wrong" alert.

## 2. Home

- **Your projects:** one row per saved project with a heatmap thumbnail, a coverage ring, the name, area, room count and when it was last changed. Touch and hold to delete; the confirmation says the backups are removed too.
- **Scan my home** (**New scan** when projects exist), or the camera and LiDAR notes from [02 §1](02-lidar-capture-roomplan.md#1-before-scanning).
- **Open demo apartment:** a 14 × 10 m flat with seven rooms. It is never saved.
- Footer: "Everything is calculated on this device. Plans are stored in the Mesh Planner folder in the Files app."

## 3. Map screen

The plan fills the screen. On top of it:

| Element | Position | Contents |
| :--- | :--- | :--- |
| Header | Top | Back button, project name, "N rooms · area" (and the floor when there are several), **More** menu. |
| Band picker | Under the header | 2.4 / 5 / 6 GHz, limited to the bands the router supports. |
| Banner | Under the band picker | "Tap the plan where your router is." or "Tap the spot where you took the measurement.", with a cancel button. Toasts (with **Undo** when possible) show here for 5 s. |
| Control rail | Right | 2D/3D, centre plan, layers menu, **Undo** (only when there is something to undo). |
| Summary card | Bottom | Coverage percentage with a verdict (Great ≥ 90 %, Good ≥ 75 %, Fair ≥ 50 %, otherwise Weak), the legend, one chip per room (worst first), **+ Satellite** and **Optimize placement**. |

The plan is fitted into the space left free between the header and the card, and to the left of the rail, so no node hides under the chrome.

### 3.1 What the plan draws

From bottom to top: the room floors, the heatmap clipped to the rooms (opacity from the layers menu), the coverage contour, furniture, walls (doors, windows and openings in their own style), backhaul lines, the signal path, calibration measurements (purple diamonds with their value), proposed positions from the optimizer (dashed rings with arrows from the current nodes), then the router and satellites. Room labels (name and coverage) are laid out by `RoomLabelLayout` so they do not overlap; small rooms show only the percentage.

### 3.2 Gestures

| Gesture | Result |
| :--- | :--- |
| Drag with one finger on empty space | Pans the plan. |
| Pinch | Zooms between 0.7× and 6×, anchored at the fingers. |
| Tap near a wall (within 14 pt) | Selects it and opens the inspector. |
| Tap elsewhere | Moves the yellow probe pin there and shows the signal at that point. |
| Drag the router or a satellite | Moves it. The heatmap updates live on a coarse grid and the coverage percentage floats above the node; releasing it runs the full grid. A light haptic marks pick-up and drop. |
| Tap a node, the pin, a room label or a room chip | Opens the inspector for it. |
| Drag the pin | Moves the measurement point. |

A node can never end up in an invalid place: it is kept inside the plan, moved into the nearest room when dropped outside one, kept out of furniture (it stays where it was) and pushed off walls.

### 3.3 Control rail and layers

- **2D/3D:** the 3D view is a read-only tilted copy of the plan (40°). Editing happens in 2D.
- **Centre plan** resets zoom and pan (dimmed when already centred).
- **Layers:** floor picker (multi-floor projects), **Signal path** (the direct ray from the serving AP to the pin with orange dots at each wall crossing, plus up to three reflections), **Show furniture**, and map opacity (*Strong map*, *Soft map*, *Plan only*).

### 3.4 More menu

| Item | What it does |
| :--- | :--- |
| Equipment and preferences | Opens the equipment sheet (§5). |
| Place the router | Next tap places the router and locks it. |
| Place router in a room | Puts the router at a room's label point. |
| Edit walls and objects | Lists the floor's walls and obstacles with their material; picking one opens the inspector. |
| Calibrate with measurements | Opens the calibration sheet (§7). |
| View in augmented reality | Opens AR; enabled only with a saved world map, an alignment and a finished heatmap. |
| Share project | Shares the `.signalsim` file ([07](07-export-sync-and-sharing.md)). |
| PDF report | Renders the report and opens a share sheet. |
| Rename | Not shown for the demo. |
| Advanced › Export to the web simulator | Shares the web JSON format. |
| Advanced › Diagnostics | Text summary for support, with **Copy**. |
| Privacy policy, Contact the developer | Links from `SupportLinks`. |

## 4. Inspector

One sheet with three heights (30 %, half, full). Up to half height the map stays interactive behind it, so the user can keep dragging the pin. **Point** in the toolbar goes back to the signal at the pin; every view ends with the list of rooms and their coverage.

### 4.1 Signal at a point

- Room name, distance to the serving AP and band.
- A gauge with the RSSI in dBm and a grade pill (Excellent, Good, Fair, Poor, No signal).
- Tiles: **Wi-Fi** speed, **Internet** speed (when a plan is set) and the serving node.
- What the grade is good for ("Great for 4K, games, and video calls" down to "No usable connection"), and a warning when a satellite's backhaul limits the speed.
- **How we calculate:** the full link budget from [03](03-rf-propagation-engine.md#4-public-api): transmit power, device margin, distance loss, each wall crossed with its material and loss, floor slab, direct signal, reflections and the final signal, then SNR, PHY rate and MCS.

The inspector uses the same model as the map, so it always shows the same value as the heatmap at that point.

### 4.2 Wall, door, window or obstacle

Name, length, exterior or interior, loss on the current band, the material list and the **Apply to** scope. See [04 §4](04-materials-and-semantics.md#4-editing-materials).

### 4.3 Router or satellite

- Name, transmit power (10–30 dBm), floor (multi-floor projects), and position steppers in 0.25 m steps.
- Router: **Fixed position** ("For example, next to the fiber or cable inlet"). A locked router shows a small lock on the map, and the optimizer leaves it in place.
- Satellite: **Link to router** (*Wi-Fi* or *Ethernet cable*), the backhaul quality, signal, parent node and available speed, and **Remove satellite** (with confirmation and an **Undo** toast).

### 4.4 Room

Name, type and area. The type sets how much the room matters to the optimizer ([10](10-placement-optimizer.md)). Below: coverage on the current band, typical signal (median), worst 10 %, the serving node, and **Measure at the center of the room**.

## 5. Equipment sheet

Opens by itself after a scan.

| Section | Settings |
| :--- | :--- |
| Router | Wi-Fi standard (5, 6, 6E, 7), device antennas (1–4), channel width on 5 GHz (20–160 MHz) and on 6 GHz. |
| Mesh network | Tri-band kit (dedicated backhaul) and the backhaul band. |
| Internet | Plan speed, used to cap the speed shown at each point. |
| Construction | Masonry, drywall or concrete. Updates every wall whose material is still automatic ([04 §3.1](04-materials-and-semantics.md#31-construction-profile)). |
| Map | Signal considered good (−60, −67 or −70 dBm), map colours (standard or colour-blind friendly), heatmap opacity. |

Changes that affect the signal are undoable and recompute the map; the internet plan only changes the speeds shown.

## 6. Best placement sheet

1. Options: **Keep the router where it is** and **Mesh satellites** (*Recommend how many*, *None (router only)*, 1–3), then **Calculate**.
2. While it runs: a progress bar, "Trying positions…" and **Cancel**. The sheet drops to 30 % height when the result is ready so the proposed positions are visible on the map.
3. Result: **Before** and **After** coverage, satellites to add or remove, and the per-room change. **Apply positions** moves the nodes (undoable, with a toast); **Discard** drops the proposal.
4. When nothing would improve by enough: "Your placement is already the best" and **Done**.

Any edit to the project while a proposal is shown cancels it, except moving the pin. See [10](10-placement-optimizer.md) for the algorithm and the comparison.

## 7. Calibration sheet

1. The user measures the signal with AirPort Utility's Wi-Fi Scanner or the router's app, puts the yellow pin where they stood and enters the value. The sheet shows the room and what the model predicts there.
2. **Add reading on ‹band›** stores the measurement. The list shows each one with its room, band and value; swipe to delete.
3. **Calibrate model** fits the model ([03 §9](03-rf-propagation-engine.md#9-calibration)) and shows the average error before and after. With 3 or more readings in different rooms it also tunes wall loss and distance attenuation.
4. **Active calibration** shows the distance exponent, wall scale and offset, and **Reset to the default model**.

## 8. Undo

Up to 30 project snapshots. Undoable: moving or nudging nodes (one step per drag), adding or removing satellites, placing the router, applying an optimizer result, material changes, room and node edits, signal-relevant equipment changes and resetting calibration. Not undoable: changing the band or floor, moving the pin and adding or removing measurements. Undo is per project and cleared when another project opens.

## 9. Accessibility

- VoiceOver: the map reads as "Coverage map" with the coverage as its value. Each node reads its name, room and backhaul, and has **Move up/down/left/right** actions (0.5 m steps). The pin reads room, signal and speed and has the same actions. Room labels and chips read "‹Room›: N % with good signal".
- Dynamic Type: the summary card stacks its buttons vertically at accessibility sizes; text scales down before truncating.
- Reduce Motion turns off band, rail and sheet animations.
- Colour-blind friendly palette ([03 §6](03-rf-propagation-engine.md#6-signal-scale)); grades are always also written as text.
- Every interactive element has an accessibility identifier used by the UI tests ([08](08-testing-and-benchmarking.md)).
