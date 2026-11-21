import CardioCore
import Foundation

public struct Peak: Sendable, Equatable {
    /// Sample index of the local maximum.
    public var index: Int
    /// Sub-sample time from parabolic interpolation, seconds.
    public var time: Double
    public var amplitude: Double
    /// Threshold the peak had to exceed.
    public var threshold: Double
}

public struct PeakDetectionConfig: Sendable, Equatable {
    public enum Threshold: Sendable, Equatable {
        /// Peak must exceed `fraction` x the maximum within +/- `windowS`/2. Adapts to slow
        /// amplitude changes (posture, contact pressure).
        case fractionOfLocalMax(fraction: Double, windowS: Double)
        /// Peak must exceed median + k x (1.4826 x MAD) of the whole signal.
        case robustZ(k: Double)
        case absolute(Double)
    }

    /// Minimum time between accepted peaks. Suppresses secondary mechanical components
    /// (e.g. aortic-closure vibration following aortic opening within the same cycle).
    public var refractoryS: Double
    public var threshold: Threshold

    public init(refractoryS: Double = 0.35, threshold: Threshold = .fractionOfLocalMax(fraction: 0.35, windowS: 2.0)) {
        self.refractoryS = refractoryS
        self.threshold = threshold
    }
}

public enum PeakDetector {
    /// Detects peaks in `x` (typically a non-negative envelope).
    /// - Parameter exclude: samples where peaks must not be reported (artifacts, gaps).
    public static func detect(_ x: [Double], sampleRateHz fs: Double, startTime: Double,
                              config: PeakDetectionConfig, exclude: [Bool]? = nil) -> [Peak] {
        let n = x.count
        guard n >= 3 else { return [] }
        let thresholds = thresholdSeries(x, fs: fs, mode: config.threshold)

        var candidates = [Int]()
        for i in 1..<(n - 1) where x[i] > x[i - 1] && x[i] >= x[i + 1] && x[i] > thresholds[i] {
            if let exclude, exclude[i] { continue }
            candidates.append(i)
        }
        // Greedy refractory suppression, strongest first (as scipy.signal.find_peaks `distance`).
        let minDistance = Int((config.refractoryS * fs).rounded())
        var keep = [Bool](repeating: true, count: candidates.count)
        let byAmplitude = candidates.indices.sorted { x[candidates[$0]] > x[candidates[$1]] }
        for k in byAmplitude where keep[k] {
            let ci = candidates[k]
            var j = k - 1
            while j >= 0 && ci - candidates[j] < minDistance { keep[j] = false; j -= 1 }
            j = k + 1
            while j < candidates.count && candidates[j] - ci < minDistance { keep[j] = false; j += 1 }
        }
        return candidates.indices.filter { keep[$0] }.map { k in
            let i = candidates[k]
            let (y0, y1, y2) = (x[i - 1], x[i], x[i + 1])
            let denom = y0 - 2 * y1 + y2
            let delta = denom != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) : 0
            return Peak(index: i, time: startTime + (Double(i) + delta) / fs, amplitude: y1, threshold: thresholds[i])
        }
    }

    static func thresholdSeries(_ x: [Double], fs: Double, mode: PeakDetectionConfig.Threshold) -> [Double] {
        let n = x.count
        switch mode {
        case .absolute(let v):
            return [Double](repeating: v, count: n)
        case .robustZ(let k):
            let v = Statistics.median(x) + k * 1.4826 * Statistics.mad(x)
            return [Double](repeating: v, count: n)
        case .fractionOfLocalMax(let fraction, let windowS):
            let half = max(1, Int(windowS * fs / 2))
            // Sliding maximum with a monotonic deque: O(n).
            var out = [Double](repeating: 0, count: n)
            var deque = [Int]()
            deque.reserveCapacity(2 * half + 1)
            var head = 0
            var right = 0
            for i in 0..<n {
                while right < n && right <= i + half {
                    while deque.count > head && x[deque[deque.count - 1]] <= x[right] { deque.removeLast() }
                    deque.append(right)
                    right += 1
                }
                while x.indices.contains(deque[head]) && deque[head] < i - half { head += 1 }
                out[i] = fraction * x[deque[head]]
                if head > 4096 { deque.removeFirst(head); head = 0 }
            }
            return out
        }
    }
}
