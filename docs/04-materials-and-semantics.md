# 04. Materials and wall semantics

What each surface is made of, how the app decides it automatically, and how the user corrects it.

Code: `Sources/MeshPlannerCore/Models/RFMaterial.swift`, `RFWallSegment.swift`, `NetworkProfile.swift`, `Sources/MeshPlannerCore/Converters/RoomPlanConverter.swift` and `ProjectRepair.swift`.

---

## 1. Material catalog

Losses are per crossing at normal incidence, before the oblique factor and the calibration scale ([03 §2.3](03-rf-propagation-engine.md#23-wall-crossings)).

| Material (`id`) | Name in the app | Loss 2.4 / 5 / 6 GHz (dB) | Reflection loss (dB) | Default thickness |
| :--- | :--- | :---: | :---: | :---: |
| `drywall` | Drywall | 3 / 4 / 5 | 10 | 0.10 m |
| `masonry_interior` | Interior masonry (brick) | 5 / 8 / 10 | 8 | 0.15 m |
| `brick` | Exterior masonry (30 cm) | 8 / 12 / 14 | 7 | 0.30 m |
| `concrete` | Reinforced concrete | 18 / 28 / 33 | 6 | 0.25 m |
| `tiled_drywall` | Tiled wall | 5 / 7 / 8 | 8 | 0.12 m |
| `glass_clear` | Clear/double glass | 3 / 5 / 6 | 6 | 0.02 m |
| `glass_lowe` | Low-E (coated) glass | 20 / 25 / 28 | 5 | 0.03 m |
| `wooden_door` | Wooden door | 3 / 4 / 5 | 12 | 0.05 m |
| `metal_door` | Metal/security door | 20 / 25 / 28 | 3 | 0.06 m |
| `wood` | Wooden furniture | 4 / 6 / 7 | 10 | 0.40 m |
| `metal` | Metal (appliance) | 30 / 35 / 38 | 2 | 0.60 m |
| `mirror` | Mirror | 12 / 15 / 18 | 2 | 0.01 m |
| `water` | Water (aquarium) | 10 / 15 / 18 | 9 | 0.40 m |
| `ceramic` | Ceramic/bathtub | 2 / 3 / 4 | 9 | 0.60 m |
| `floor_slab` | Concrete floor slab | 20 / 28 / 33 | 6 | 0.20 m |
| `open_door` | Open doorway | 0 / 0 / 0 | none | 0.05 m |
| `empty_water` | Empty container | 0 / 0 / 0 | none | 0.40 m |

- A material with 0 dB on every band is **transparent**: it never blocks, never reflects, does not count for wall clearance and does not stop the optimizer from placing a node there.
- `floor_slab` is used only as the loss between floors.
- Older projects may contain `glass` (the original Low-E glass). It still decodes; repair turns automatic windows into clear glass.
- The wall picker offers drywall, interior masonry, brick, concrete, tiled wall, both glasses, both doors, mirror and open doorway. The obstacle picker offers metal, wood, water, ceramic, mirror and open doorway.

In JSON a material is stored with its `crossingLoss` array `[2.4, 5, 6]`; shorter arrays are padded with their last value, so files from older versions still load.

## 2. Wall kinds

Each `RFWallSegment` has a `kind`:

| Kind | Meaning |
| :--- | :--- |
| `wall` | Structural or partition wall. |
| `door` | Door leaf (open, wooden or metal). |
| `window` | Window glass. |
| `opening` | Doorway or passage without a door. |
| `obstacle` | One face of a furniture/appliance box; faces of the same box share a `groupId`. |

When a file has no kind, it is inferred: a non-zero group means obstacle, an open doorway means opening, wooden or metal doors mean door, glass means window, anything else is a wall.

## 3. Automatic classification

### 3.1 Construction profile

The equipment sheet sets `NetworkProfile.construction`, which decides the default walls:

| Profile | Interior walls | Exterior walls |
| :--- | :--- | :--- |
| Masonry (default) | Interior masonry | Exterior masonry (brick) |
| Drywall | Drywall | Exterior masonry (brick) |
| Concrete | Reinforced concrete | Reinforced concrete |

Changing the profile updates every wall that still has an automatic material (`isMaterialAuto`).

### 3.2 Exterior or interior

A wall is exterior when, probing 0.25 m (then 0.4 m) to each side of its midpoint, a room lies on exactly one side. If rooms lie on both sides it is interior. Without room polygons, walls near the outer bounding box are treated as exterior.

### 3.3 Doors, windows and openings

RoomPlan reports doors, windows and openings separately. The converter cuts the parent wall over the gap (found by `parentIdentifier`, otherwise the nearest aligned wall within 0.3 m) and fills it:

| Opening | Material |
| :--- | :--- |
| Door, open or unknown | Open doorway (0 dB) |
| Door, closed, interior | Wooden door |
| Door, closed, exterior | Metal/security door |
| Window | Clear/double glass |
| Opening | Open doorway |

### 3.4 Objects

Objects become RF obstacles only when they change the signal. Each becomes a rotated box of four segments with its own `groupId` (from 1001):

| RoomPlan category | Material |
| :--- | :--- |
| Refrigerator, oven, dishwasher, washer-dryer, stove | Metal |
| Storage | Wooden furniture |
| Fireplace | Exterior masonry |
| Bathtub, sink, toilet | Ceramic |
| Television | Mirror |
| Bed, sofa, table, chair, stairs and others | Shown as furniture, no RF effect |

### 3.5 Older projects

`ProjectRepair.upgradeIfNeeded` runs once on projects saved before schema 3: it cuts doors and windows that were drawn over walls, rebuilds rooms, renames walls and reclassifies automatic materials as above. Manual choices are never overwritten.

## 4. Editing materials

- Tap a wall, door, window or obstacle on the 2D map (or pick it from **More › Edit walls and objects**) to open the inspector. It shows the name, length, exterior or interior, and the loss on the current band, then the material list with each material's loss on that band.
- **Apply to** sets the scope: *This one only*, *Same material*, *All exterior* or *All interior*, always on the same floor and for the same kind of segment. An obstacle's material always applies to all of its faces.
- A manual choice sets `isMaterialAuto = false`, so later profile changes and repairs leave it alone. The inspector footer says whether the material was estimated or chosen.
- Material changes are undoable, and the map recomputes immediately.
