# 06. AR walkthrough

The AR walkthrough lays the coverage map on the real floor and shows the estimated signal where the phone is, so the user can walk the home and see where the signal drops.

Code: `Sources/MeshPlannerUI/AR/ARWalkthroughView.swift` (`ARWalkthroughView`, `ARWalkSession`, `ARWalkDelegate`) and `WorldAlignment` in `Sources/MeshPlannerCore/Models/FloorplanProject.swift`.

---

## 1. Requirements

**More › View in augmented reality** is enabled only when all of these hold:

- the project has a saved world map (`.<id>.worldmap`, written when a scan finishes normally, see [02 §5](02-lidar-capture-roomplan.md#5-project-creation));
- the project has a `WorldAlignment` (set by the scan; the demo has none);
- the heatmap has finished computing.

The device must support `ARWorldTrackingConfiguration` and camera access must be allowed. Each missing piece shows a specific message in the status pill (with **Open Settings** for the camera).

## 2. Relocalization

1. The world map is unarchived and set as `initialWorldMap` of an `ARWorldTrackingConfiguration` with horizontal plane detection. On LiDAR devices, scene reconstruction (`.mesh`) is turned on and used for occlusion, so real walls and furniture hide the overlay behind them.
2. The session runs with `.resetTracking` and `.removeExistingAnchors`. The status reads **Point at the walls you scanned** until ARKit reports normal tracking, which means it has matched the scan.
3. When tracking becomes normal the overlay is placed and the status changes to **Map on the floor**. If tracking is lost later (interruption, fast motion), the live reading is hidden and the status returns to relocalizing until it recovers.

The propagation model is built once, off the main actor, when AR opens.

## 3. Placing the map

The heatmap image (the same `CGImage` the 2D map shows, at the 0.1 m grid) is drawn on a flat quad:

- Size: the plan's width × depth in metres, with vertices at plan (0, 0) to (width, depth). The quad is two-sided, so it is visible from any angle.
- Material: `UnlitMaterial` with the heatmap as texture, 70 % opacity.
- Position: the world point of plan (0, 0), `alignment.worldPoint(fromPlan: .zero)`, at the floor's elevation plus 2 cm (to avoid z-fighting with the real floor).
- Orientation: a rotation of `alignment.rotation` around the world Y axis.

### Alignment math

The converter stores how the scan was rotated and shifted ([02 §4.2](02-lidar-capture-roomplan.md#42-normalization)):

$$p_{plan} = R(\theta)\,(x_{world}, z_{world}) + offset \qquad p_{world} = R(-\theta)\,(p_{plan} - offset)$$

`elevation(for:floorHeight:)` returns the floor's recorded elevation from `floorElevations` or, for older projects, `floorY + floor × floorHeight`.

## 4. Live reading

Every 0.2 s (camera frames are throttled in the delegate and again in the session) the camera position is converted to a plan point with `planPoint(worldX:worldZ:)` and evaluated with `FloorplanViewModel.reading(...)`, the same function the 2D inspector uses. The card at the bottom shows:

- the room (or "Here" outside rooms) and a grade icon in the scale's colour;
- RSSI and the effective speed (limited by backhaul and the internet plan);
- what the grade is good for.

The reading uses the band and floor selected on the map when AR was opened.

## 5. Errors

| Situation | Message |
| :--- | :--- |
| Device without world tracking | "This device does not support augmented reality." |
| Camera denied | "Camera access is turned off. Allow camera access in Settings to use augmented reality." |
| No world map or it cannot be read | "No environment map for this project. Scan again to use AR." |
| No alignment | "This project has no augmented reality data. Scan again to use AR." |
| ARKit session failure, or the overlay cannot be built | The error, then "Close AR and reopen it to retry, or scan again." The session is paused. |

Closing AR pauses the session and removes all anchors.

## 6. Known limits

- The overlay is placed once. Edits made while AR is open (there is no way to make them from the AR screen) are not reflected until AR is reopened.
- There is no timeout or guidance when relocalization takes long; the user is expected to point at walls they scanned.
- The world map comes from the end of the scan and stays on the device that scanned. A project saved after a scan error, or imported from a `.signalsim` file, has no world map; it must be scanned again to use AR.
- Only the current floor's map is shown. Moving to another floor in the real home does not switch the overlay.
- Accuracy depends on ARKit relocalization; alignment can only be checked on a physical LiDAR device ([08](08-testing-and-benchmarking.md#6-device-only-validation)).
