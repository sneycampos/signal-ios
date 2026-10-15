# 03. RF propagation engine

The single signal model behind every number in the app: the heatmap, the coverage percentage, per-room grades, the point inspector, backhaul, calibration and the optimizer all call `PropagationModel`. There is no second implementation (no GPU shader, no simplified copy).

Code: `Sources/MeshPlannerCore/Engine/RFPropagationEngine.swift`, with `SignalField.swift`, `LinkRateModel.swift`, `BackhaulPlanner.swift`, `Calibrator.swift` and the models in `Sources/MeshPlannerCore/Models/`.

---

## 1. Model in one line

**Received signal = transmit power + calibration offset − device margin − free-space loss − wall losses − floor-slab losses**, plus the power of first-order (one-bounce) specular reflections. At each point the client uses the strongest access point; powers from different APs are never added.

All coordinates are metres on the floor plan (`x` to the right, `y` down the plan), one plan per floor.

## 2. Direct path

### 2.1 Free-space loss

$$FSL(d) = FSPL_{1\,m}(band) + 10 \cdot n \cdot \log_{10}(\max(d,\ 0.5\,m))$$

| Band | Centre frequency | $FSPL_{1\,m} = 20\log_{10}(f_{MHz}) - 27.55$ |
| :--- | :---: | :---: |
| 2.4 GHz | 2437 MHz | 40.19 dB |
| 5 GHz | 5200 MHz | 46.77 dB |
| 6 GHz | 6105 MHz | 48.16 dB |

The path-loss exponent $n$ is `Calibration.pathLossExponent`: **2.5** when uncalibrated (free space would be 2.0; furniture and people push real homes higher), or the fitted value (1.6–3.6) after calibration.

### 2.2 Transmit power

$$P_{eff} = P_{tx} + offset_{cal} - 3\ dB$$

`txPower` is the AP's EIRP (20 dBm by default). `offsetDb` comes from calibration (0 when uncalibrated). The 3 dB `deviceMarginDb` accounts for a phone receiving worse than a reference antenna.

### 2.3 Wall crossings

For every wall segment the ray crosses:

$$\Delta L = L_{material}(band) \cdot k_{wall} \cdot \min\left(\frac{1}{\cos\theta},\ 2\right), \qquad \cos\theta = \frac{|\vec r \cdot \vec n|}{\|\vec r\|}$$

- $L_{material}$ is the material's loss at normal incidence (see [04 Materials](04-materials-and-semantics.md)); $k_{wall}$ is `Calibration.wallLossScale` (1.0 by default).
- **Transparent** materials (open doorway, empty container: 0 dB on every band) never block.
- Geometry tolerances, in metres so they do not depend on wall length:
  - walls within 1 cm of either end of the ray are ignored (`endpointTolerance`);
  - walls are extended 1.5 cm past their ends so that rays cannot slip through joints (`jointExtension`);
  - crossings closer than 3 cm along the ray count once, keeping the largest loss (`mergeDistance`), so a corner where two walls meet is not counted twice.
- **Obstacles** (fridge, bathtub, cabinet…) are boxes of four segments sharing a `groupId`; a ray is charged once per obstacle, not once per face.

### 2.4 Between floors

For an AP on another floor:

- distance is 3D: $d = \sqrt{d_{plan}^2 + (\Delta floors \cdot h_{floor})^2}$ with `NetworkProfile.floorHeight` (2.8 m by default);
- slab loss $= L_{floor\ slab}(band) \cdot k_{wall} \cdot \Delta floors \cdot \min(1/\cos\theta, 2)$, where $\cos\theta$ is the vertical share of the path (concrete slab: 20 / 28 / 33 dB);
- wall loss is the average of the 2D crossings on the AP's floor and on the receiver's floor; floors in between add only slab loss.

$$RSSI_{direct} = P_{eff} - FSL(d) - \sum \Delta L_{walls} - L_{slab}$$

## 3. Reflections

One-bounce specular reflections by the image method, on the same floor only:

1. A wall can reflect if its material has a reflection loss (open doorways do not) and it is at least 0.3 m long.
2. Transmitter and receiver must be on the same side of the wall. The transmitter is mirrored across the wall line, and the image-to-receiver ray must hit the finite segment.
3. Upper bound: $P_{ceiling} = P_{eff} - FSL(d_{unfolded}) - L_{reflection}$. Paths whose ceiling is below **max(direct − 15 dB, −100 dBm)** are skipped (`reflectionCutoff`; they would change the result by less than 0.14 dB).
4. The two legs (transmitter → reflection point → receiver) pay their own wall crossings, excluding the reflecting wall.
5. Powers add in milliwatts:

$$RSSI = 10\log_{10}\left(10^{RSSI_{direct}/10} + \sum_i 10^{RSSI_{refl,i}/10}\right)$$

Every reflector that passes the cutoff contributes; there is no fixed maximum count.

## 4. Public API

```swift
let model = PropagationModel(walls: project.walls, band: .five,
                             calibration: project.calibration,
                             floorHeight: project.profile.floorHeight)

model.rssi(from: ap, to: point, floor: 0)                 // direct + reflections, dBm
model.best(from: aps, to: point, floor: 0)                // best server: (rssi, index)
model.linkBudget(from: ap, to: point, floor: 0)           // inspector breakdown
model.pathLoss(from: a, floorA: 0, to: b, floorB: 0)      // direct-path loss incl. margin, no reflections
model.effectiveLoss(from: a, floorA: 0, to: b, floorB: 0) // loss incl. reflections (optimizer tables)
```

`LinkBudget` is what the point inspector shows: transmit power, device margin, distance, free-space loss, wall and floor losses, every crossing (wall, point, loss, angle), every reflection, the direct RSSI, the final RSSI and the reflection gain. Because it uses the same code, **the inspector always equals the map** at that point (a test enforces it).

`RFPropagationEngine.shared` keeps a small convenience API (`getRSSI`, `computeDirectPath`, `computeReflectionPaths`) with the default uncalibrated model.

## 5. Signal field and coverage

`SignalFieldGenerator.compute(model:accessPoints:floor:mask:scale:)` evaluates `best(...)` at the centre of every interior cell of a `FieldGrid`, in parallel over rows, and records the RSSI and the serving AP.

| Use | Grid |
| :--- | :--- |
| Map while dragging (live) | 0.25 m, at most 5,000 cells |
| Map at rest (full) and optimizer comparison | 0.1 m, at most 30,000 cells |
| Project thumbnail | 0.15 m, at most 8,000 cells |
| Optimizer search | about 0.34 m, at most 960 points (see [10](10-placement-optimizer.md)) |

`FieldGrid.covering` uses square cells and grows the cell size if the target would exceed the cell budget.

- **Interior mask:** only cells whose centre lies inside a room polygon count (`InteriorMask`, scanline fill). Without rooms, the whole rectangle counts.
- **Coverage:** `CoverageSummary` holds `coveredPercent` (cells ≥ coverage threshold), `medianRSSI`, `p10RSSI` and `cellCount`. Per-room coverage adds a grade from the median and the AP that serves most of the room.
- **Heatmap image:** one pixel per cell, coloured by `SignalScale`, with a 0.6 m Gaussian blur restricted to each room (display only; numbers use the unblurred values).
- **Contours:** marching squares at the coverage threshold draw the coverage edge on the map.

## 6. Signal scale

`SignalScale` holds the thresholds, colours and labels used everywhere.

| Grade | Default rule |
| :--- | :--- |
| Excellent | ≥ −55 dBm |
| Good (covered) | ≥ coverage threshold, −67 dBm by default (configurable from −80 to −58) |
| Fair | ≥ −75 dBm |
| Poor | ≥ −85 dBm |
| No signal | < −85 dBm |

There are two palettes, standard and colour-blind safe (`HeatmapPalette`). Both have a visible step at the coverage threshold.

## 7. Rate and throughput

`LinkRateModel.estimate(rssi:band:profile:)`:

1. Noise floor $= -174 + 10\log_{10}(width_{Hz}) + 7$ dB (noise figure 7 dB): −94 dBm at 20 MHz, −88 at 80 MHz, −85 at 160 MHz.
2. SNR = RSSI − noise floor for the profile's channel width on that band.
3. MCS = the highest index allowed by the Wi-Fi standard (Wi-Fi 5: 9, or 7 on 2.4 GHz; Wi-Fi 6/6E: 11; Wi-Fi 7: 13) whose minimum SNR is met (5, 8, 11, 14, 18, 22, 24, 26, 30, 32, 35, 37, 40, 42 dB for MCS 0–13).
4. PHY rate = 802.11ax per-stream rate at 20 MHz × width factor (40: 2.0, 80: 4.19, 160: 8.37, 320: 16.74) × client streams (1–4) × 0.9 for Wi-Fi 5.
5. Real throughput ≈ 60 % of the PHY rate. In the inspector it is further limited by the satellite's backhaul and the internet plan, when set.

## 8. Backhaul

`BackhaulPlanner.plan(...)` builds the mesh tree on `NetworkProfile.effectiveBackhaulBand`:

- wired satellites hang from the router at 940 Mbps;
- wireless satellites are attached greedily by the widest path: each round, the satellite–node pair with the highest throughput, where throughput = min(parent throughput, link rate) × 0.5 (× 1 with a dedicated backhaul radio);
- link quality: good ≥ −65 dBm, at the limit ≥ −70 dBm, weak below.

The optimizer's backhaul constraint (≥ −70 dBm) uses the direct-path loss on the same band.

## 9. Calibration

`Calibrator.fit(measurements:walls:accessPoints:profile:)` compares measured RSSI values with the model's prediction at the same points:

- with 3 or more measurements it searches the path-loss exponent (1.6–3.6, step 0.1) and the wall-loss scale (0.4–2.0, step 0.1); with fewer, only the offset;
- for each pair, the offset is the mean residual (clamped to ±10 dB);
- the pair with the lowest RMS error wins, but only if it beats the current calibration.

The result stores the RMS error before and after and the sample count. Removing calibration restores the defaults.
