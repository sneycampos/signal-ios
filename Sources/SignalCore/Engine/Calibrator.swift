import Foundation

/// Fits the propagation model to real readings: path-loss exponent, wall-loss scale and a global offset.
public enum Calibrator {
    public struct Result: Equatable, Sendable {
        public let calibration: Calibration
        public let rmsBefore: Float
        public let rmsAfter: Float
    }

    public static func fit(
        measurements: [SignalMeasurement],
        walls: [RFWallSegment],
        accessPoints: [RFAccessPoint],
        profile: NetworkProfile,
        current: Calibration = .uncalibrated,
        token: CancellationToken? = nil
    ) -> Result? {
        guard !measurements.isEmpty, accessPoints.contains(where: \.isActive) else { return nil }

        func residuals(_ calibration: Calibration) -> [Float] {
            var models: [RFBand: PropagationModel] = [:]
            return measurements.map { m in
                let model = models[m.band] ?? PropagationModel(walls: walls, band: m.band, calibration: calibration, floorHeight: profile.floorHeight)
                models[m.band] = model
                return m.rssi - model.best(from: accessPoints, to: m.position, floor: m.floor).rssi
            }
        }
        func rms(_ values: [Float]) -> Float {
            (values.reduce(0) { $0 + $1 * $1 } / Float(values.count)).squareRoot()
        }

        let before = rms(residuals(current))
        var best = current
        var bestError = before

        // With few readings only an offset is identifiable; with three or more, fit exponent and wall scale too.
        let exponents: [Float] = measurements.count >= 3 ? stride(from: 1.6, through: 3.6, by: 0.1).map { Float($0) } : [current.pathLossExponent]
        let scales: [Float] = measurements.count >= 3 ? stride(from: 0.4, through: 2.0, by: 0.1).map { Float($0) } : [current.wallLossScale]
        for n in exponents {
            for k in scales {
                guard token?.isCancelled != true else { return nil }
                let trial = Calibration(pathLossExponent: n, wallLossScale: k)
                let r = residuals(trial)
                let offset = max(-10, min(10, r.reduce(0, +) / Float(r.count)))
                let error = rms(r.map { $0 - offset })
                if error < bestError {
                    bestError = error
                    best = Calibration(pathLossExponent: n, wallLossScale: k, offsetDb: offset)
                }
            }
        }
        best.rmsErrorBefore = before
        best.rmsErrorAfter = bestError
        best.sampleCount = measurements.count
        return Result(calibration: best, rmsBefore: before, rmsAfter: bestError)
    }
}
