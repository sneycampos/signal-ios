# Phase 7: Export, Sync & Sharing

> **Data interchange specifications, Web companion sync (`web/wifi.html`), USDZ 3D export, and PDF Wi-Fi Audit Reports.**

---

## 1. Universal JSON Interchange Schema

The iOS app and the Web version (`web/wifi.html`) share an identical JSON representation. This ensures that any apartment scanned on an iPhone can be instantly opened, viewed, or edited on a desktop browser.

```json
{
  "version": "1.0",
  "name": "My Apartment Scan",
  "timestamp": "2026-09-26T20:00:00Z",
  "dimensions": {
    "width": 14.0,
    "depth": 10.0,
    "wallHeight": 2.7
  },
  "materials": [
    {
      "id": "drywall",
      "name": "Drywall",
      "crossingLoss": [3.0, 4.0, 5.0],
      "reflectionLoss": 10.0,
      "color": "#d9d4c7"
    }
  ],
  "walls": [
    {
      "id": "wall_living_north",
      "p1": [0.0, 6.0],
      "p2": [7.0, 6.0],
      "materialId": "concrete",
      "thickness": 0.25,
      "height": 2.7,
      "active": true
    }
  ],
  "openings": [
    {
      "wallId": "wall_living_north",
      "offset": 3.5,
      "width": 0.9,
      "isOpen": true
    }
  ],
  "obstacles": [
    {
      "id": "refrigerator_1",
      "name": "Refrigerator",
      "x": 10.2,
      "z": 0.1,
      "width": 0.8,
      "depth": 0.7,
      "materialId": "metal"
    }
  ],
  "accessPoints": [
    {
      "id": "router_main",
      "name": "Main Router",
      "x": 8.0,
      "z": 4.8,
      "txPower": 20.0,
      "isSatellite": false
    }
  ]
}
```

---

## 2. Sync with Web Companion (`web/wifi.html`)

- **AirDrop / Share Sheet:** The iOS app can export a `.signalsim` file (which is the JSON bundle).
- **Embedded Web Player:** Opening `web/wifi.html` and dragging the `.signalsim` file into the browser viewport dynamically replaces the default apartment floorplan with the exact walls and furniture scanned by the user's iPhone!

---

## 3. PDF Wi-Fi Health Audit Report

For network technicians, landlords, and smart home installers, the iOS app can generate a formal, multi-page vector PDF report:

1. **Cover Page:** Apartment 3D dollhouse screenshot, summary coverage score ($92\% \ge -67\text{ dBm}$), average RSSI ($-54\text{ dBm}$), router make/model notes.
2. **Room-by-Room Scorecard:**
   - Living Room: $98\%$ Good (Average: $-48\text{ dBm}$, $866\text{ Mbps}$) — **Grade A**
   - Office: $94\%$ Good (Average: $-52\text{ dBm}$, $650\text{ Mbps}$) — **Grade A**
   - Bedroom: $86\%$ Good (Average: $-64\text{ dBm}$, $433\text{ Mbps}$) — **Grade B**
   - Bathroom: $58\%$ Weak (Average: $-74\text{ dBm}$, $195\text{ Mbps}$) — **Grade D (Action Recommended)**
3. **Hardware Recommendations:**
   - Suggestions for placing a mesh satellite in the hallway to eliminate the bathroom concrete shadow.
