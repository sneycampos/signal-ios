# Phase 2: LiDAR Capture & Apple RoomPlan Pipeline

> **Technical specification for real-time room scanning, parametric geometry extraction, and semantic classification.**

---

## 1. Overview of Apple RoomPlan

Apple's **RoomPlan** framework uses the LiDAR Scanner and camera sensors on Pro iPhones and iPads to detect physical surfaces, openings, and structural objects in 3D space.

Unlike raw mesh scanning (which produces non-semantic point clouds or millions of irregular triangles), RoomPlan outputs a **clean, parametric CAD representation**:
- Flat wall planes with length, height, and orientation.
- Exact doorway openings and door swing states (open / closed).
- Window boundaries.
- Categorized furniture items (e.g. `.refrigerator`, `.bathtub`, `.storage`, `.sofa`).

This makes RoomPlan data directly compatible with electromagnetic raycast testing.

---

## 2. Capture Session Architecture

```swift
import SwiftUI
import RoomPlan

final class RoomCaptureManager: ObservableObject, RoomCaptureSessionDelegate {
    @Published var isScanning: Bool = false
    @Published var currentRoom: CapturedRoom?
    @Published var completedStructure: CapturedStructure?
    
    private var captureSession: RoomCaptureSession?
    
    func startScan() {
        let config = RoomCaptureSession.Configuration()
        captureSession = RoomCaptureSession()
        captureSession?.delegate = self
        captureSession?.run(configuration: config)
        isScanning = true
    }
    
    func stopScan() {
        captureSession?.stop()
        isScanning = false
    }
    
    // Delegate callbacks
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async {
            self.currentRoom = room
        }
    }
    
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        // Process final room structure
    }
}
```

---

## 3. Parametric Geometry Extraction Pipeline

When `captureSession` yields a `CapturedRoom` (or `CapturedStructure` for multi-room apartments):

### A. Wall Segments
Each wall in `CapturedRoom.walls` is a `CapturedRoom.Surface`:
- **Dimensions:** `surface.dimensions.x` (length), `surface.dimensions.y` (height).
- **Transform Matrix:** `simd_float4x4` defining position and rotation in world coordinates.
- **Conversion to 2D Simulation Segment:**
  1. Extract center position $(c_x, c_z)$ from the 4th column of the transform matrix.
  2. Extract rotation angle $\theta$ around the Y-axis.
  3. Half-length vector: $\vec{v} = (\frac{L}{2} \cos\theta, \frac{L}{2} \sin\theta)$.
  4. Segment endpoints:
     $$p_1 = (c_x - v_x, c_z - v_z), \quad p_2 = (c_x + v_x, c_z + v_z)$$
  5. Default material heuristic assignment based on room context.

### B. Doors and Openings
- `CapturedRoom.doors`:
  - Position and width.
  - State: `.open` (acts as opening / zero crossing loss) or `.closed` (acts as wooden door with 3–5 dB loss).
- `CapturedRoom.openings`:
  - Doorway cutouts in walls are subtracted from the wall segment, splitting one physical wall into two sub-segments with an open passage between them.

### C. Windows
- `CapturedRoom.windows`:
  - Tagged as `Low-E glass` (20 dB loss at 2.4 GHz, 25 dB at 5 GHz, 28 dB at 6 GHz).

### D. RF-Blocking Structural Objects
RoomPlan identifies object categories (`CapturedRoom.Object.Category`):
- `.refrigerator` $\to$ Converted to a 4-sided metal bounding box (35 dB attenuation).
- `.bathtub` $\to$ Converted to a 4-sided water bounding box (15 dB attenuation).
- `.storage` / `.wardrobe` $\to$ Converted to a dense wood/metal bookshelf (10–25 dB attenuation).
- Neutral furniture (`.sofa`, `.bed`, `.table`) $\to$ Kept as low-poly visual 3D assets with 0 dB RF attenuation.

---

## 4. Multi-Room Stitching (`CapturedStructure`)

For multi-room scanning (e.g. 3-bedroom apartment):
1. **iOS 17+ Multi-Room API:** RoomPlan's `StructureBuilder` stitches sequential room captures into one unified coordinate system using spatial visual-inertial odometry.
2. **Boundary Cleanup:** Shared partition walls between adjacent rooms are merged into a single segment to avoid duplicate ray collisions.
3. **Bounding Normalization:** The outer extents of the merged structure are translated so $(X_{\min}, Z_{\min}) = (0, 0)$.

---

## 5. Non-LiDAR Fallback Mode

For devices without a LiDAR sensor (standard iPhone models):
- **Pre-Built Architectural Templates:** Studio, 2-Bedroom, 3-Bedroom, Duplex.
- **Floorplan Photo Importer:** Ability to import a 2D floorplan photo/blueprint and trace walls with snap-to-grid guidelines.
- **Web Project Sync:** Import any project created in `web/wifi.html`.
