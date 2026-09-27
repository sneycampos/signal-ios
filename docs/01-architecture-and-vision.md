# Phase 1: Architecture & Technical Vision

> **Comprehensive system design and technical architecture for Signal on iOS.**

---

## 1. Vision & Purpose

`Signal: Wi-Fi LiDAR` bridges the physical world of real homes and offices with physical radio frequency (RF) propagation mathematics. Using Apple's LiDAR Scanner and the **RoomPlan API**, the app scans rooms in seconds, reconstructs the floorplan with semantic understanding (walls, doors, windows, metal appliances, bathtubs), and runs a real-time electromagnetic wave propagation simulation directly on the device's Apple Silicon GPU via **Metal**.

The user can drag access points (routers, mesh nodes), observe coverage heatmaps in 2.4, 5, and 6 GHz, identify dead zones, inspect the exact dB link-budget waterfall of each wall crossing, and project the Wi-Fi field onto their real floor using Augmented Reality.

---

## 2. Technology Stack & Frameworks

| Subsystem | Framework / Technology | Justification |
| :--- | :--- | :--- |
| **UI & Application State** | `SwiftUI` + `Observation` (`@Observable`) | Native iOS Human Interface Guidelines, fluid animations, Dynamic Type, Dark Mode |
| **Room & Floor Scanning** | `RoomPlan` (`RoomCaptureSession`, `RoomCaptureView`) | Apple's official LiDAR-powered parametric room reconstruction framework |
| **3D Rendering (Dollhouse)** | `RealityKit` / `SceneKit` + `MetalKit` | High-performance 3D scene graph, physically-based materials, custom shader textures |
| **RF Heatmap Compute** | `Metal` (Metal Shading Language - MSL) | 120 FPS real-time parallel ray casting and multipath image method compute on Apple GPU |
| **Augmented Reality (AR Mode)** | `ARKit` (`ARWorldTrackingConfiguration`) | Millimeter-accurate horizontal plane anchoring and world camera tracking |
| **File I/O & Interchange** | `Codable` (JSON) + `USDZ` / `ModelIO` | Interoperable floorplan schema compatible with `web/wifi.html` and 3D CAD tools |
| **Audio & Haptics** | `CoreHaptics` + `UIImpactFeedbackGenerator` | Subtle tactile feedback when placing routers, snapping to walls, or auto-optimizing |

---

## 3. High-Level System Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                        SwiftUI Presentation Layer                      │
│  ┌────────────────────────┬──────────────────────────────────────────┐ │
│  │ RoomCaptureView (Scan) │ Main Floorplan View (3D Dollhouse / Top) │ │
│  └───────────┬────────────┴────────────────────┬─────────────────────┘ │
│              │                                 │                       │
│              ▼                                 ▼                       │
│  ┌───────────────────────┐       ┌───────────────────────────────────┐ │
│  │ RoomPlanCaptureManager│       │   FloorplanInteractiveViewModel   │ │
│  └───────────┬───────────┘       └─────────────────┬─────────────────┘ │
└──────────────┼─────────────────────────────────────┼───────────────────┘
               │                                     │
               ▼                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│                            Domain / Core Model                         │
│  • CapturedStructure / RFEnvironment (Walls, Openings, Obstacles)      │
│  • MaterialCatalog (Dielectric properties, attenuation per band)       │
│  • AccessPointGroup (Router, Satellites, Probe, Client Devices)        │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     RF Simulation Engine (Dual-Core)                   │
│  ┌───────────────────────────────────┬───────────────────────────────┐ │
│  │        Swift CPU Engine           │       Metal GPU Compute       │ │
│  │   • Pure getRSSI() function       │   • Parallel Heatmap Compute  │ │
│  │   • Probe link-budget waterfall   │   • Dynamic 120 FPS Texture   │ │
│  │   • Auto-Place grid search        │   • Wavefront pulse generator │ │
│  └───────────────────────────────────┴───────────────────────────────┘ │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     Visualization & AR Output Layer                    │
│  • RealityKit 3D Dollhouse Viewport (Custom floor shader with texture) │
│  • ARKit World-Space Floor Overlay (Augmented reality in real room)    │
│  • Universal JSON Export & PDF Wi-Fi Health Audit Generation           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Coordinate System & Normalization

1. **Units:** 1.0 unit = 1.0 meter (Apple ARKit standard).
2. **LiDAR Coordinates (RoomPlan):** $+X$ is Right, $+Y$ is Up, $+Z$ is Backward (standard camera-space orientation).
3. **Simulation Plane:**
   - The RF simulation occurs on a horizontal plane at device elevation ($Y = 1.0\text{ m}$ above the floor plane $Y = 0.0\text{ m}$).
   - The 3D bounding box of the apartment is normalized to a ground plane spanning $(0 \dots X_{\max})$ and $(0 \dots Z_{\max})$.
4. **Precision:**
   - Wall coordinates: Centimeter precision ($\pm 0.01\text{ m}$).
   - RSSI calculations: Floating point (`Float32`) with accuracy within $\pm 0.05\text{ dBm}$.

---

## 5. Privacy, Performance & Device Requirements

- **Local-First & Offline:** 100% of scanning, geometry processing, and RF simulation occurs strictly on-device. No floorplans or camera streams ever leave the iPhone.
- **Battery & Thermal Efficiency:**
  - Dynamic GPU throttling: While the user is interacting/dragging, the Metal compute kernel executes at 120 FPS. When idle, the frame rate reduces to 30 FPS with static caching.
  - Zero redundant allocations: Wall segment buffers and ray pools are pre-allocated in unified memory (`MTLResourceStorageModeShared`).
