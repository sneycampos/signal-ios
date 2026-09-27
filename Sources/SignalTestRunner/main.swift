import Foundation
import simd
import SignalCore

/// Command-line verification and benchmark of the core: `swift run -c release SignalTestRunner`.
struct Runner {
    var failures = 0

    mutating func check(_ condition: Bool, _ name: String, _ detail: String) {
        print("\(condition ? "[PASS]" : "[FAIL]") \(name): \(detail)")
        if !condition { failures += 1 }
    }

    func time(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    mutating func run() {
        let project = DefaultApartmentFixture.makeProject()
        let model = PropagationModel(walls: project.walls, band: .five)
        let router = project.accessPoints[0]
        let probe = project.probe

        let budget = model.linkBudget(from: router, to: probe, floor: 0)
        check(abs(budget.finalRssiDbm - model.rssi(from: router, to: probe, floor: 0)) < 0.001, "Inspector = map",
              String(format: "probe %.1f dBm (direct %.1f dBm, +%.1f dB reflections)", budget.finalRssiDbm, budget.directRssiDbm, budget.reflectionGainDb))

        let grid = FieldGrid.covering(width: project.width, depth: project.depth, targetCell: 0.1, maxCells: 30_000)
        let mask = InteriorMask(grid: grid, polygons: project.rooms.map(\.polygon))
        var field: SignalField?
        let fieldMs = time { field = SignalFieldGenerator.compute(model: model, accessPoints: project.accessPoints, floor: 0, mask: mask, scale: .default) }
        let coverage = field?.coverage.coveredPercent ?? 0
        check(field != nil, "Full field", String(format: "%d cells, %.1f ms, coverage %.1f%%", grid.count, fieldMs, coverage))
        if let field, let value = field.value(at: probe) {
            check(abs(value - budget.finalRssiDbm) < 3, "Map cell at probe", String(format: "%.1f dBm vs probe %.1f dBm", value, budget.finalRssiDbm))
        }

        var proposal: PlacementProposal?
        let request = PlacementRequest(walls: project.walls, rooms: project.rooms, accessPoints: project.accessPoints, profile: project.profile, width: project.width, depth: project.depth, satellites: .automatic)
        let optimizerMs = time { proposal = PlacementOptimizer.optimize(request) }
        if let proposal {
            let estimates = proposal.estimatedCoverageBySatelliteCount.map { String(format: "%.0f%%", $0) }.joined(separator: " → ")
            check(true, "Optimizer", String(format: "%.0f ms, recommends %d satellite(s), estimates by count: %@", optimizerMs, proposal.recommendedSatelliteCount, estimates))
        } else {
            check(false, "Optimizer", "no proposal")
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
    }
}

var runner = Runner()
runner.run()
exit(runner.failures == 0 ? 0 : 1)
