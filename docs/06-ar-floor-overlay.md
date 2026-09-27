# Phase 6: Augmented Reality (AR) Pass-Through Mode

> **Architecture and implementation of true ARKit + RealityKit floor projection for live physical walkthroughs.**

---

## 1. Concept: Physical World RF Overlay

In AR mode, the user switches from the virtual 3D dollhouse model to their iPhone's camera pass-through view.

As they walk through their actual hallway, kitchen, and bedrooms:
- The RF Wi-Fi heatmap is **projected directly onto the physical floor**.
- The walls detected during the RoomPlan session serve as physical occlusion masks: as you look through an open doorway, you see the signal spreading from the router in the next room.
- As the user walks, their real-time device location acts as a dynamic **Signal Probe**, displaying live signal strength in dBm, SNR, and estimated throughput directly in an AR HUD.

---

## 2. AR Tracking & Anchor Alignment

```
┌────────────────────────────────────────────────────────┐
│                   ARKit World Session                  │
│  • ARWorldTrackingConfiguration                        │
│  • Scene Reconstruction with LiDAR Mesh                │
│  • Plane Detection (.horizontal)                       │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼ Alignment Matrix
┌────────────────────────────────────────────────────────┐
│             RoomPlan to World Space Transform          │
│  • Scanned floor origin (0, 0, 0) aligned to detected  │
│    ARPlaneAnchor via persistent WorldMap / Relocalization│
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│               RealityKit Render Pipeline               │
│  • Floor Entity with Custom Emissive Surface Shader    │
│  • Real-time Metal Heatmap Texture Sampled in World XZ │
│  • Dynamic Occlusion Mesh (Walls hide far-side signal) │
└────────────────────────────────────────────────────────┘
```

---

## 3. Shader Projection on Physical Surfaces

In RealityKit, a custom `CustomMaterial` or `SurfaceShader` samples the Metal compute texture using the world-space $(X, Z)$ coordinate of the physical floor:

```metal
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

[[visible]]
void wifiFloorSurfaceShader(realitykit::surface_parameters params) {
    auto surface = params.surface();
    
    // World space position of current floor point
    float3 worldPos = params.geometry().world_position();
    
    // Normalize coordinates into apartment bounds
    float u = (worldPos.x - uniforms.originX) / uniforms.width;
    float v = (worldPos.z - uniforms.originZ) / uniforms.depth;
    
    if (u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        half4 signalColor = heatmapTexture.sample(s, float2(u, v));
        
        // Blend with subtle camera video pass-through
        surface.set_emissive_color(signalColor.rgb * signalColor.a * 0.85);
        surface.set_opacity(signalColor.a * uniforms.revealAlpha);
    } else {
        surface.set_opacity(0.0);
    }
}
```

---

## 4. Live Walkthrough Probe HUD

- As the user walks through the home with the phone in their hand:
  - Phone world position $(x, z)$ is sampled at 60 Hz.
  - An AR beacon icon floats above the phone's projected floor footprint.
  - Floating pill: `📶 Living Room: -52 dBm | 866 Mbps (Excellent)`.
  - When crossing behind a concrete wall or refrigerator: the color shifts to Orange/Red and a subtle haptic warning (`UINotificationFeedbackGenerator(.warning)`) alerts the user to signal degradation.
