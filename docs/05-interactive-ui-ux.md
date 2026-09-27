# Phase 5: Interactive 3D UI & UX (SwiftUI & RealityKit)

> **Design patterns, gestural direct manipulation, camera transitions, and inspector sheets adhering to Apple HIG.**

---

## 1. Core Viewport & Visual Hierarchy

The interface is built strictly according to **Apple Human Interface Guidelines (HIG)**:
- **Phone-first, portrait orientation** with adaptive landscape support on iPad.
- **Full-Screen 3D Viewport:** RealityKit / SceneKit canvas filling the safe area, with semi-transparent frosted glass panels (`.ultraThinMaterial`) floating above.
- **Top Navigation Bar:**
  - Left: Project title & room switcher menu.
  - Center: Camera preset segmented picker (`Dollhouse`, `Top 2D`, `AR View`).
  - Right: Export / Share button (`UIActivityViewController`).

---

## 2. Interactive Gestural Controls

### A. Direct Manipulation of Access Points
- **Hit Testing:** Generous invisible interaction cylinders ($0.6\text{m}$ radius) around the 3D Router and Satellite models.
- **Drag & Drop:**
  - One finger touches the router $\to$ camera orbit freezes $\to$ router moves continuously over the floor plane ($Y = 0$).
  - **Zero-Latency Response:** Position updates immediately in the touch event handler; Metal compute uniform updates simultaneously.
  - Haptic feedback (`UIImpactFeedbackGenerator(.light)`) on pick up and drop.
  - Wall collision avoidance: The router cannot be placed inside a solid wall or metal refrigerator.

### B. Pinning the Signal Probe
- Tap anywhere on the floor $\to$ pins the 3D Signal Probe.
- Instantly displays:
  - Direct line of sight from the active AP.
  - Screen-space 3D crossing badges at each intersected wall.
  - One-bounce reflection rays with bounce spark particles.
  - Slide-up Ray Inspector card.

---

## 3. The Hero Controls

### A. "Reveal Signal" Slider
- A prominent floating slider $(0 \dots 1.0)$ controlling the signal visualization:
  - At $0.0$: Clean architectural dollhouse; walls are solid, heatmap is hidden.
  - Moving to $1.0$: Walls smoothly fade to $15\%$ opacity with highlighted colored edges; the RF signal heatmap fades in on the floor plane; animated spherical wavefront pulses emit from the router.

### B. Frequency Band Segmented Control
- Switch between **2.4 GHz**, **5 GHz**, and **6 GHz**.
- Smooth 400 ms cross-dissolve animation between band textures.
- Real-time link speeds recalculate across all client devices.

---

## 4. Modal Sheets & Inspector Cards

### A. Ray Inspector & Link Budget Waterfall Sheet
- Displayed when tapping a probe point or client device.
- **Waterfall Chart Breakdown:**
  1. Transmitter Power: $+20.0\text{ dBm}$ (Green bar)
  2. Free Space Path Loss ($1\text{m} + \text{dist}$): $-58.4\text{ dB}$ (Red bar)
  3. Wall 1 Crossing (Material, Angle of incidence): $-15.5\text{ dB}$ (Orange bar)
  4. Wall 2 Crossing (Concrete, $15^\circ$ incidence): $-29.0\text{ dB}$ (Orange bar)
  5. Direct RSSI Total: $-82.9\text{ dBm}$
  6. $+N$ One-Bounce Multipath Gain: $+6.8\text{ dB}$
  7. **Final Combined RSSI:** $-76.1\text{ dBm}$ (Negotiated speed: $195\text{ Mbps}$, SNR: $18.9\text{ dB}$)
- **Parity Badge:** Displays CPU vs Metal GPU delta ($\le 0.05\text{ dB}$).

### B. Auto-Place Placement Sheet
- One-tap optimization button: *"⚡ Find Optimal AP Positions"*.
- Runs coarse grid search ($0.5\text{m}$) then refines at $0.1\text{m}$.
- Displays a before/after split card:
  - Before: $62\%$ coverage $\ge -67\text{ dBm}$
  - After: $91\%$ coverage $\ge -67\text{ dBm}$
- Button *"Apply Placement"* animates routers smoothly to their optimal coordinates.
