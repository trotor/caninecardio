import Accelerate
import CardioCore
import Foundation

/// A uniformly sampled signal. `valid[i] == false` marks samples interpolated across a gap
/// in the original (irregular) timestamps that was too long to bridge reliably.
public struct UniformSignal: Sendable, Equatable {
    public var startTime: Double
    public var sampleRateHz: Double
    public var values: [Double]
    public var valid: [Bool]

    public init(startTime: Double, sampleRateHz: Double, values: [Double], valid: [Bool]? = nil) {
        self.startTime = startTime
        self.sampleRateHz = sampleRateHz
        self.values = values
        self.valid = valid ?? Array(repeating: true, count: values.count)
    }

    public var count: Int { values.count }
    public func time(at index: Double) -> Double { startTime + index / sampleRateHz }
    public var times: [Double] { (0..<values.count).map { time(at: Double($0)) } }
    public var durationS: Double { Double(values.count) / sampleRateHz }

    public func replacingValues(_ v: [Double]) -> UniformSignal {
        UniformSignal(startTime: startTime, sampleRateHz: sampleRateHz, values: v, valid: valid)
    }
}

public enum Resampler {
    /// Linear interpolation of irregularly timed samples onto a uniform grid.
    ///
    /// Core Motion timestamps jitter and samples can be dropped. Grid points inside an original
    /// gap longer than `maxGapS` are still interpolated (filters need continuous input) but are
    /// marked invalid so downstream steps can reject detections there.
    public static func linear(times: [Double], values: [Double], rateHz: Double, maxGapS: Double? = nil) -> UniformSignal {
        precondition(times.count == values.count)
        guard times.count >= 2, let t0 = times.first, let t1 = times.last, t1 > t0 else {
            return UniformSignal(startTime: times.first ?? 0, sampleRateHz: rateHz, values: values)
        }
        let maxGap = maxGapS ?? 2.5 / rateHz
        let n = Int(((t1 - t0) * rateHz).rounded(.down)) + 1
        var out = [Double](repeating: 0, count: n)
        var valid = [Bool](repeating: true, count: n)
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) / rateHz
            while j < times.count - 2 && times[j + 1] < t { j += 1 }
            let (ta, tb) = (times[j], times[j + 1])
            let dt = tb - ta
            if dt <= 0 {
                out[i] = values[j + 1]
            } else {
                let f = min(1, max(0, (t - ta) / dt))
                out[i] = values[j] + f * (values[j + 1] - values[j])
            }
            if dt > maxGap { valid[i] = false }
        }
        return UniformSignal(startTime: t0, sampleRateHz: rateHz, values: out, valid: valid)
    }
}

public enum Detrend {
    public static func removeMean(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        return vDSP.add(-vDSP.mean(x), x)
    }

    /// Removes the least-squares straight line.
    public static func linear(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return removeMean(x) }
        let idx = vDSP.ramp(withInitialValue: 0.0, increment: 1.0, count: n)
        let mx = Double(n - 1) / 2
        let my = vDSP.mean(x)
        let xc = vDSP.add(-mx, idx)
        let slope = vDSP.dot(xc, vDSP.add(-my, x)) / vDSP.sumOfSquares(xc)
        return vDSP.subtract(x, vDSP.add(my, vDSP.multiply(slope, xc)))
    }
}

public enum Envelope {
    /// RMS envelope: square, centred moving average over `windowS`, square root.
    public static func rms(_ x: [Double], sampleRateHz: Double, windowS: Double) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        let w = max(1, Int((windowS * sampleRateHz).rounded()))
        let sq = vDSP.square(x)
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + sq[i] }
        var out = [Double](repeating: 0, count: n)
        let half = w / 2
        for i in 0..<n {
            let a = max(0, i - half), b = min(n, i - half + w)
            out[i] = (max(0, prefix[b] - prefix[a]) / Double(max(1, b - a))).squareRoot()
        }
        return out
    }
}

public enum Periodicity {
    /// Normalised autocorrelation of `x` (mean removed) over lags [`minLagS`, `maxLagS`].
    ///
    /// Returns the *first* interior local maximum whose value is at least `acceptFraction` of the
    /// strongest local maximum, so that the fundamental period is chosen rather than one of its
    /// multiples. `value` is near 1 for a strongly periodic signal and near 0 for noise.
    public static func autocorrelationPeak(_ x: [Double], sampleRateHz: Double, minLagS: Double,
                                           maxLagS: Double, acceptFraction: Double = 0.85) -> (value: Double, lagS: Double)? {
        let n = x.count
        let lo = max(1, Int(minLagS * sampleRateHz)), hi = min(n - 2, Int(maxLagS * sampleRateHz))
        guard hi > lo + 1 else { return nil }
        let xc = Detrend.removeMean(x)
        let energy = vDSP.sumOfSquares(xc)
        guard energy > 0 else { return nil }
        var r = [Double](repeating: 0, count: hi + 2)
        xc.withUnsafeBufferPointer { p in
            for lag in (lo - 1)...(hi + 1) {
                var dot = 0.0
                vDSP_dotprD(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                // Unbiased normalisation so long lags are not penalised by fewer overlap terms.
                r[lag] = dot / energy * Double(n) / Double(n - lag)
            }
        }
        let maxima = (lo...hi).filter { r[$0] > r[$0 - 1] && r[$0] >= r[$0 + 1] }
        guard let strongest = maxima.map({ r[$0] }).max() else { return (0, .nan) }
        // With no positive correlation (e.g. a recording dominated by gross motion), scaling the
        // maximum by acceptFraction would raise the threshold above it; use the maximum itself.
        let threshold = strongest > 0 ? acceptFraction * strongest : strongest
        let chosen = maxima.first { r[$0] >= threshold } ?? maxima[0]
        return (r[chosen], Double(chosen) / sampleRateHz)
    }
}
