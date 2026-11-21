import Foundation

/// Describes how regularly a stream was actually sampled.
///
/// Core Motion does not deliver samples at perfectly regular intervals, may batch them and may
/// drop them. These statistics are computed from the recorded timestamps only.
public struct SamplingStatistics: Codable, Sendable, Equatable {
    public var sampleCount: Int
    /// Last minus first timestamp, seconds.
    public var spanS: Double
    /// (count - 1) / span. `nil` when fewer than two samples.
    public var effectiveRateHz: Double?
    public var meanIntervalS: Double?
    public var medianIntervalS: Double?
    public var stdIntervalS: Double?
    public var minIntervalS: Double?
    public var maxIntervalS: Double?
    /// Intervals <= 0 (duplicate or out-of-order timestamps).
    public var nonIncreasingIntervals: Int
    /// Intervals longer than `gapFactor` x median interval.
    public var gapCount: Int
    /// Sum over gaps of round(interval / median) - 1.
    public var estimatedMissingSamples: Int
    public var gapFactor: Double

    public static let empty = SamplingStatistics(
        sampleCount: 0, spanS: 0, effectiveRateHz: nil, meanIntervalS: nil, medianIntervalS: nil,
        stdIntervalS: nil, minIntervalS: nil, maxIntervalS: nil, nonIncreasingIntervals: 0,
        gapCount: 0, estimatedMissingSamples: 0, gapFactor: 1.5)

    public init(sampleCount: Int, spanS: Double, effectiveRateHz: Double?, meanIntervalS: Double?,
                medianIntervalS: Double?, stdIntervalS: Double?, minIntervalS: Double?,
                maxIntervalS: Double?, nonIncreasingIntervals: Int, gapCount: Int,
                estimatedMissingSamples: Int, gapFactor: Double) {
        self.sampleCount = sampleCount
        self.spanS = spanS
        self.effectiveRateHz = effectiveRateHz
        self.meanIntervalS = meanIntervalS
        self.medianIntervalS = medianIntervalS
        self.stdIntervalS = stdIntervalS
        self.minIntervalS = minIntervalS
        self.maxIntervalS = maxIntervalS
        self.nonIncreasingIntervals = nonIncreasingIntervals
        self.gapCount = gapCount
        self.estimatedMissingSamples = estimatedMissingSamples
        self.gapFactor = gapFactor
    }

    public static func compute(timestamps t: [Double], gapFactor: Double = 1.5) -> SamplingStatistics {
        guard t.count >= 2 else {
            var s = SamplingStatistics.empty
            s.sampleCount = t.count
            s.gapFactor = gapFactor
            return s
        }
        var intervals = [Double]()
        intervals.reserveCapacity(t.count - 1)
        var nonIncreasing = 0
        for i in 1..<t.count {
            let d = t[i] - t[i - 1]
            if d <= 0 { nonIncreasing += 1 }
            intervals.append(d)
        }
        let span = t[t.count - 1] - t[0]
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
        let median = Statistics.median(intervals)
        var gaps = 0
        var missing = 0
        if median > 0 {
            for d in intervals where d > gapFactor * median {
                gaps += 1
                missing += max(0, Int((d / median).rounded()) - 1)
            }
        }
        return SamplingStatistics(
            sampleCount: t.count,
            spanS: span,
            effectiveRateHz: span > 0 ? Double(t.count - 1) / span : nil,
            meanIntervalS: mean,
            medianIntervalS: median,
            stdIntervalS: variance.squareRoot(),
            minIntervalS: intervals.min(),
            maxIntervalS: intervals.max(),
            nonIncreasingIntervals: nonIncreasing,
            gapCount: gaps,
            estimatedMissingSamples: missing,
            gapFactor: gapFactor)
    }
}

/// Small, allocation-light statistics helpers shared across modules.
public enum Statistics {
    public static func mean(_ v: [Double]) -> Double {
        v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
    }

    /// Population standard deviation.
    public static func std(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let m = mean(v)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }

    /// Sample standard deviation (n - 1).
    public static func sampleStd(_ v: [Double]) -> Double {
        guard v.count > 1 else { return .nan }
        let m = mean(v)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    public static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    /// Median absolute deviation (unscaled).
    public static func mad(_ v: [Double]) -> Double {
        let m = median(v)
        return median(v.map { abs($0 - m) })
    }
}
