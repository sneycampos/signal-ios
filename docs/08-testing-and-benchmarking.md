# Phase 8: Testing, Verification & Benchmarking

> **Automated test strategy, CPU vs Metal GPU mathematical verification, and thermal/memory performance gates.**

---

## 1. Test Suite Architecture

```
ios-app/Tests/
├── RFEngineTests/
│   ├── FreeSpaceLossTests.swift      // FSPL validation across bands
│   ├── WallCrossingTests.swift       // Oblique angle loss verification
│   ├── ReflectionPathTests.swift     // Image method reflection validation
│   └── ParityAuditTests.swift        // 100-point CPU vs Metal compute parity (delta < 0.05 dB)
├── RoomPlanConverterTests/
│   ├── SurfaceToSegmentTests.swift   // Wall dimensions & endpoints transform
│   ├── ObjectCategoryTests.swift     // Refrigerator/bathtub auto-tagging
│   └── MultiRoomStitchingTests.swift // Overlapping wall deduplication
└── BenchmarkTests/
    ├── ComputeKernelBench.swift      // 512x512 texture compute latency (< 8 ms)
    └── AutoPlaceOptimizerBench.swift // Multi-point grid search (< 2.5 s)
```

---

## 2. Mathematical Parity Audit Test (Automated Gate)

To guarantee that the iOS Metal shader and the Swift pure CPU engine yield identical results down to decimal places:

```swift
import XCTest
@testable import SignalCore

final class ParityAuditTests: XCTestCase {
    func testCPUAndMetalParityAcrossRandomPoints() throws {
        let walls = TestApartmentFixture.defaultWalls
        let router = RFAccessPoint(id: "router", x: 0.5, z: 0.5, txPower: 20.0)
        let engine = RFPropagationEngine()
        
        var maxDelta: Float = 0.0
        
        // Sample 100 pseudo-random points across the floorplan
        for _ in 0..<100 {
            let rx = Float.random(in: 0.5...13.5)
            let rz = Float.random(in: 0.5...9.5)
            let pt = SIMD2<Float>(rx, rz)
            
            let cpuRSSI = engine.getRSSI_CPU(at: pt, band: .fiveGHz, accessPoints: [router], walls: walls, reflectionsOn: true)
            let metalRSSI = engine.getRSSI_Metal(at: pt, band: .fiveGHz, accessPoints: [router], walls: walls, reflectionsOn: true)
            
            let delta = abs(cpuRSSI - metalRSSI)
            maxDelta = max(maxDelta, delta)
            
            XCTAssertLessThan(delta, 0.05, "Parity failure at (\(rx), \(rz)): CPU=\(cpuRSSI) vs Metal=\(metalRSSI), delta=\(delta)")
        }
        
        print("100-point CPU vs Metal parity audit PASSED. Max delta: \(maxDelta) dB (limit 0.05 dB)")
    }
}
```

---

## 3. Performance & Thermal Benchmarks

| Metric | Target Gate | Failure Threshold | Action on Failure |
| :--- | :---: | :---: | :--- |
| **Metal Kernel Dispatch** | $< 4.0\text{ ms}$ | $> 8.3\text{ ms}$ ($< 120\text{ FPS}$) | Downsample texture from $512\times512$ to $384\times384$ |
| **Touch-to-Pixel Latency** | $< 16\text{ ms}$ | $> 33\text{ ms}$ (2-frame lag) | Direct uniform update in touch handler |
| **Auto-Place Grid Search** | $< 2.0\text{ s}$ | $> 3.5\text{ s}$ | Coarsen candidate search from $0.5\text{m}$ to $0.8\text{m}$ |
| **Peak Memory Footprint** | $< 120\text{ MB}$ | $> 200\text{ MB}$ | Flush temporary RealityKit entities |
| **Thermal State** | `.nominal` | `.serious` / `.critical` | Drop frame rate from 120 FPS to 60 FPS |
