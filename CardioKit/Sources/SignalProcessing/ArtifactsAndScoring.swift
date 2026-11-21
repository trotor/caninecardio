import CardioCore
import Foundation

public struct MotionArtifactConfig: Sendable, Equatable {
    public var windowS: Double = 0.5
    /// A window is an artifact if its RMS exceeds `factor` x the median window RMS.
    public var factor: Double = 4
    /// Also mark this much time on each side of a flagged window.
    public var marginS: Double = 0.25
    public init() {}
}

public enum MotionArtifactDetector {
    /// Flags samples dominated by gross motion, using windowed RMS of the (detrended) signal.
    /// Input should be broadband (e.g. 0.5-30 Hz band-passed magnitude), not the cardiac band.
    public static func mask(_ x: [Double], sampleRateHz fs: Double, config: MotionArtifactConfig = .init()) -> [Bool] {
        let n = x.count
        let w = max(1, Int(config.windowS * fs))
        guard n >= w else { return [Bool](repeating: false, count: n) }
        let windows = stride(from: 0, to: n, by: w).map { a -> Double in
            let b = min(n, a + w)
            return (x[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)).squareRoot()
        }
        let median = Statistics.median(windows)
        var mask = [Bool](repeating: false, count: n)
        let margin = Int(config.marginS * fs)
        for (k, rms) in windows.enumerated() where median > 0 && rms > config.factor * median {
            let a = max(0, k * w - margin), b = min(n, (k + 1) * w + margin)
            for i in a..<b { mask[i] = true }
        }
        return mask
    }
}

/// Compares detected beat times with reference beat times (synthetic ground truth now; a
/// simultaneous ECG later, after correcting for the electromechanical delay).
public struct BeatMatchResult: Sendable, Equatable {
    public var truePositives: Int
    public var falsePositives: Int
    public var falseNegatives: Int
    /// detected - reference, seconds, for matched pairs.
    public var timingErrors: [Double]
    /// Detected IBI - reference IBI (ms) where both ends of both intervals are matched.
    public var intervalErrorsMs: [Double]

    public var sensitivity: Double {
        truePositives + falseNegatives == 0 ? .nan : Double(truePositives) / Double(truePositives + falseNegatives)
    }
    public var positivePredictiveValue: Double {
        truePositives + falsePositives == 0 ? .nan : Double(truePositives) / Double(truePositives + falsePositives)
    }
    public var meanTimingErrorS: Double { Statistics.mean(timingErrors) }
    public var timingErrorSDS: Double { Statistics.std(timingErrors) }
    public var medianAbsIntervalErrorMs: Double { Statistics.median(intervalErrorsMs.map(abs)) }
}

public enum BeatMatcher {
    /// One-to-one matching: each reference beat takes the nearest unmatched detection within
    /// `toleranceS` after shifting detections by `offsetS` (systematic latency).
    public static func match(detected: [Double], reference: [Double], toleranceS: Double = 0.1,
                             offsetS: Double = 0, within range: ClosedRange<Double>? = nil) -> BeatMatchResult {
        let det = detected.map { $0 - offsetS }.filter { range?.contains($0) ?? true }.sorted()
        let ref = reference.filter { range?.contains($0) ?? true }.sorted()
        var used = [Bool](repeating: false, count: det.count)
        var matchOf = [Int?](repeating: nil, count: ref.count)
        var j = 0
        for (i, r) in ref.enumerated() {
            while j < det.count && det[j] < r - toleranceS { j += 1 }
            var best: Int?
            var k = j
            while k < det.count && det[k] <= r + toleranceS {
                if !used[k], best == nil || abs(det[k] - r) < abs(det[best!] - r) { best = k }
                k += 1
            }
            if let best { used[best] = true; matchOf[i] = best }
        }
        let tp = matchOf.compactMap { $0 }.count
        let errors = ref.indices.compactMap { i in matchOf[i].map { det[$0] - ref[i] } }
        var ibiErrors = [Double]()
        for i in 1..<max(1, ref.count) {
            if let a = matchOf[i - 1], let b = matchOf[i], b == a + 1 {
                ibiErrors.append(((det[b] - det[a]) - (ref[i] - ref[i - 1])) * 1000)
            }
        }
        return BeatMatchResult(truePositives: tp, falsePositives: det.count - tp, falseNegatives: ref.count - tp,
                               timingErrors: errors, intervalErrorsMs: ibiErrors)
    }
}
