# Phase 4: Materials & Semantics UX

> **Catalog of RF dielectric properties, heuristic inference rules, and interactive material override UX.**

---

## 1. Material Dielectric Catalog

| Material Key | Display Name | Crossing Loss (2.4 / 5 / 6 GHz) | Reflection Loss | Default Thickness | Visual Material Color |
| :--- | :--- | :---: | :---: | :---: | :---: |
| `drywall` | Drywall / Plasterboard | **3 / 4 / 5 dB** | **10 dB** | 0.12 m | `#d9d4c7` (warm grey) |
| `tiled_drywall` | Tiled Drywall (Bathroom) | **5 / 7 / 8 dB** | **8 dB** | 0.12 m | `#b8c9cf` (soft ceramic) |
| `wooden_door` | Wooden Door | **3 / 4 / 5 dB** | **12 dB** | 0.05 m | `#a0703c` (natural wood) |
| `brick` | Brick (Structural) | **8 / 12 / 14 dB** | **7 dB** | 0.30 m | `#b5553a` (terracotta) |
| `concrete` | Reinforced Concrete | **18 / 28 / 33 dB** | **6 dB** | 0.25 m | `#7d7f82` (slate stone) |
| `glass` | Low-E Coated Glass | **20 / 25 / 28 dB** | **5 dB** | 0.03 m | `#7fb6d6` (translucent cyan) |
| `water` | Water (Aquarium/Tub) | **10 / 15 / 18 dB** | **9 dB** | 0.40–0.80 m | `#2f6fd1` (deep azure) |
| `metal` | Metal (Appliances/Cabinet) | **30 / 35 / 38 dB** | **2 dB** | 0.60 m | `#9aa3ad` (brushed steel) |

---

## 2. Heuristic Semantic Inference Rules

When RoomPlan finishes scanning an apartment, `MaterialInferenceEngine` automatically assigns materials based on spatial geometry:

1. **Perimeter Exterior Walls:**
   - Any wall forming the outer convex hull of the apartment is automatically classified as **Brick (0.30m)**.
2. **Wet Room Detection:**
   - If RoomPlan detects a toilet, sink, or bathtub inside a closed boundary, all surrounding walls default to **Tiled Drywall**.
3. **Partition Interior Walls:**
   - Non-perimeter dividing walls default to **Drywall (0.12m)**.
4. **Load-Bearing Concrete Corridors:**
   - Walls exceeding $0.20\text{m}$ thickness during scan or bounding long central spans default to **Reinforced Concrete**.
5. **Openings & Doors:**
   - If the door is detected open: $0\text{ dB}$ (empty passage).
   - If the door is closed: **Wooden Door (3/4/5 dB)**.
6. **Kitchen Appliances:**
   - The bounding box of any detected `.refrigerator` is automatically assigned as **Metal Box** (high RF blockage + high reflection).

---

## 3. Interactive Override UX (SwiftUI)

When a user taps any wall in the 3D Dollhouse or 2D floorplan:
1. **Selection Highlight:** The selected wall glows with an accent outline (`Color.accentColor`).
2. **Inspector Bottom Sheet:**
   - Wall Name (e.g. *"Living Room North Wall"*).
   - Length, Height, and Thickness (calculated from LiDAR).
   - Segment Material Picker: Horizontal scroll of material chips with color badge, dB loss badge, and material name.
   - Thickness fine-tuning slider ($0.05\text{m} \dots 0.50\text{m}$).
   - Toggle: *"Is Load-Bearing Concrete"* (instantly switches from 4 dB to 28 dB at 5 GHz).
3. **Live Recalculation:** The moment a material chip is tapped, the Metal compute kernel and CPU link budget update in $< 5\text{ ms}$, immediately showing the new signal distribution.
