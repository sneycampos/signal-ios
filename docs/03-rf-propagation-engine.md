# Phase 3: RF Propagation Engine (Swift & Metal)

> **Mathematical RF propagation model, ray-tracing mechanics, and high-performance Metal compute kernel.**

---

## 1. Physical Propagation Formulas

The physical model implemented in the iOS app is identical to our verified Web reference implementation, ensuring mathematical parity ($\le 0.05\text{ dB}$).

### A. Free-Space Path Loss (FSPL)
$$PL(d) = FSPL_{1\text{m}} + 10 \cdot n \cdot \log_{10}(\max(d, 0.5))$$
Where path loss exponent $n = 2.0$, and $FSPL_{1\text{m}}$ depends on frequency band:
- **2.4 GHz (2437 MHz):** $FSPL_{1\text{m}} = 40.2\text{ dB}$
- **5.0 GHz (5200 MHz):** $FSPL_{1\text{m}} = 46.8\text{ dB}$
- **6.0 GHz (6105 MHz):** $FSPL_{1\text{m}} = 48.2\text{ dB}$

### B. Oblique Wall Crossing Loss
For each wall segment crossed by the ray:
$$\Delta L = L_{\text{material}} \cdot \min\left(\frac{1}{\cos\theta}, 2.0\right)$$
Where $\theta$ is the angle between the propagation ray vector $\vec{r}$ and the wall's normal vector $\vec{n}$:
$$\cos\theta = \frac{|\vec{r} \cdot \vec{n}|}{\|\vec{r}\|}$$
*(Note: Objects like refrigerators or bathtubs count once per crossing of their bounding outline).*

### C. Direct Path RSSI
$$RSSI_{\text{direct}} = P_{\text{tx}} - PL(d) - \sum \Delta L_{\text{walls}}$$
Default $P_{\text{tx}} = 20.0\text{ dBm}$ (adjustable 10–23 dBm). Noise floor is $-95.0\text{ dBm}$. $SNR = RSSI + 95$.

### D. One-Bounce Multipath Reflections (Image Method)
For each candidate reflective wall:
1. Mirror access point position across the wall line: $S' = S - 2(\vec{h}_S \cdot \vec{n}) \vec{n}$.
2. Test if ray $(S' \to RX)$ intersects the finite wall segment within bounds.
3. Compute total unfolded distance $d_{\text{unfold}} = \|RX - S'\|$.
4. Compute Leg 1 ($S \to I$) and Leg 2 ($I \to RX$) wall crossing losses.
5. Early Culling Optimization:
   $$P_{\text{unobstructed}} = P_{\text{tx}} - PL(d_{\text{unfold}}) - L_{\text{reflection}}$$
   If $P_{\text{unobstructed}} < RSSI_{\text{direct}} - 22.0\text{ dB}$ or $P_{\text{unobstructed}} < -92.0\text{ dBm}$, **abort** ray tracing for this path.
6. Power summation:
   $$P_{\text{total, mW}} = 10^{\frac{RSSI_{\text{direct}}}{10}} + \sum 10^{\frac{RSSI_{\text{refl}, i}}{10}}$$
   $$RSSI_{\text{final}} = \max\left(10 \cdot \log_{10}(P_{\text{total, mW}}), RSSI_{\text{direct}}\right)$$

---

## 2. Swift Pure Function API

```swift
public protocol RFEngineProtocol {
    func getRSSI(
        at point: SIMD2<Float>,
        band: RFBand,
        accessPoints: [RFAccessPoint],
        walls: [RFWallSegment],
        reflectionsOn: Bool
    ) -> Float
    
    func computeDirectPath(
        from ap: RFAccessPoint,
        to rx: SIMD2<Float>,
        band: RFBand,
        walls: [RFWallSegment]
    ) -> RFDirectPathResult
    
    func computeReflectionPaths(
        from ap: RFAccessPoint,
        to rx: SIMD2<Float>,
        band: RFBand,
        walls: [RFWallSegment],
        directRSSI: Float?
    ) -> [RFReflectionPath]
}
```

---

## 3. Metal GPU Compute Architecture (`HeatmapCompute.metal`)

To sustain 120 FPS on iPhone 16 Pro displays while dragging access points:

1. **Output Texture:** A 2D RGBA texture (`MTLTexture`) with dimensions matching the apartment grid (e.g. $512 \times 512$ texels, representing a $14\text{m} \times 10\text{m}$ area at $2.7\text{cm}$ resolution).
2. **Buffer Passing:**
   - Wall segments passed as a constant structured buffer: `device const RFWallSegmentGPU* walls [[buffer(0)]]`.
   - Access points passed as uniform buffer: `constant RFAccessPointGPU* aps [[buffer(1)]]`.
   - Simulation parameters (band, time, reveal, reflections toggle): `constant SimulationUniforms& uniforms [[buffer(2)]]`.
3. **Execution Grid:**
   - 2D Threadgroup: $16 \times 16$ threads per threadgroup.
   - Dispatch threads matching texture size (`MTLSize(width: 512, height: 512, depth: 1)`).
4. **Color Mapping:**
   - Direct translation of RSSI values into hex stops inside the compute kernel:
     - $\ge -45\text{ dBm} \to \text{Dark Green (\#0b6e3a)}$
     - $-55\text{ dBm} \to \text{Light Green (\#2fb34a)}$
     - $-67\text{ dBm} \to \text{Yellow (\#e7d33a)}$
     - $-75\text{ dBm} \to \text{Orange (\#f08a24)}$
     - $-82\text{ dBm} \to \text{Red (\#d7262e)}$
     - $\le -90\text{ dBm} \to \text{Dark Red / Black (\#2a0d10)}$
5. **Zero Copy in RealityKit:**
   - The computed `MTLTexture` is bound directly as the `baseColor` texture of a `UnlitMaterial` or custom surface shader on the floor geometry.
