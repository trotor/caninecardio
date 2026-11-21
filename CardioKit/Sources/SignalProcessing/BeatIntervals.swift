import CardioCore
import Foundation

/// Interval between two consecutive *mechanical* beat candidates.
///
/// These come from chest motion, not from an ECG. They are not R-R intervals: the mechanical
/// event lags electrical depolarisation by a variable pre-ejection period.
public struct BeatInterval: Sendable, Equatable {
    public enum Flag: String, Sendable, Hashable, CaseIterable {
        /// Shorter or longer than the configured physiological limits.
        case outOfRange
        /// Deviates from the local median by more than the allowed fraction (possible missed,
        /// extra, premature or double-detected beat).
        case abruptChange
        /// Overlaps a motion artifact or a sampling gap.
        case unreliableSegment
    }

    public var startTime: Double
    public var endTime: Double
    public var flags: Set<Flag>

    public var milliseconds: Double { (endTime - startTime) * 1000 }
    public var isAccepted: Bool { flags.isEmpty }
}

public struct BeatIntervalConfig: Sendable, Equatable {
    /// 250 ms = 240 beats/min.
    public var minMs: Double = 250
    /// 2000 ms = 30 beats/min.
    public var maxMs: Double = 2000
    /// Allowed relative deviation from the median of neighbouring intervals.
    /// Must accommodate respiratory modulation, which in dogs can be large.
    public var maxRelativeDeviation: Double = 0.35
    /// Number of neighbouring intervals (each side) used for the local median.
    public var neighbourhood: Int = 4

    public init() {}
}

public enum BeatIntervals {
    /// - Parameter unreliable: closure returning true if the time span overlaps an artifact/gap.
    public static func compute(beatTimes: [Double], config: BeatIntervalConfig = .init(),
                               unreliable: ((Double, Double) -> Bool)? = nil) -> [BeatInterval] {
        guard beatTimes.count >= 2 else { return [] }
        var intervals = (1..<beatTimes.count).map {
            BeatInterval(startTime: beatTimes[$0 - 1], endTime: beatTimes[$0], flags: [])
        }
        let ms = intervals.map(\.milliseconds)
        for i in intervals.indices {
            if ms[i] < config.minMs || ms[i] > config.maxMs { intervals[i].flags.insert(.outOfRange) }
            let lo = max(0, i - config.neighbourhood), hi = min(ms.count - 1, i + config.neighbourhood)
            let neighbours = (lo...hi).filter { $0 != i }.map { ms[$0] }
            if neighbours.count >= 2 {
                let med = Statistics.median(neighbours)
                if abs(ms[i] - med) > config.maxRelativeDeviation * med { intervals[i].flags.insert(.abruptChange) }
            }
            if let unreliable, unreliable(intervals[i].startTime, intervals[i].endTime) {
                intervals[i].flags.insert(.unreliableSegment)
            }
        }
        return intervals
    }
}

/// Exploratory summary of accepted intervals. Values are `nil` unless reliability is sufficient.
public struct IntervalSummary: Sendable, Equatable {
    public enum Reliability: Sendable, Equatable {
        case sufficient
        case insufficient([String])
    }

    public var intervalCount: Int
    public var acceptedCount: Int
    public var acceptedFraction: Double
    public var reliability: Reliability
    public var meanIntervalMs: Double?
    public var meanRateBPM: Double?
    /// Standard deviation of accepted intervals (exploratory "SDNN"-like metric).
    public var sdMs: Double?
    /// Root mean square of successive differences between *adjacent accepted* intervals.
    public var rmssdMs: Double?

    public var isReliable: Bool { reliability == .sufficient }

    public struct Requirements: Sendable, Equatable {
        public var minAccepted = 10
        public var minAcceptedFraction = 0.8
        public var minPeriodicity = 0.3
        public var maxUnreliableFraction = 0.3
        /// Allowed relative disagreement between the median detected interval and the dominant
        /// period of the envelope. Catches systematic double detection (two mechanical
        /// components per cycle) or systematically missed beats, which interval-to-interval
        /// plausibility checks cannot see.
        public var maxPeriodMismatch = 0.25
        public init() {}
    }

    public static func summarize(_ intervals: [BeatInterval], periodicity: Double?, dominantPeriodS: Double? = nil,
                                 unreliableFraction: Double, requirements: Requirements = .init()) -> IntervalSummary {
        let accepted = intervals.filter(\.isAccepted)
        let fraction = intervals.isEmpty ? 0 : Double(accepted.count) / Double(intervals.count)
        var reasons = [String]()
        if accepted.count < requirements.minAccepted {
            reasons.append("Only \(accepted.count) accepted intervals (need \(requirements.minAccepted)).")
        }
        if fraction < requirements.minAcceptedFraction {
            reasons.append(String(format: "Only %.0f%% of intervals passed plausibility checks.", fraction * 100))
        }
        if let periodicity, periodicity < requirements.minPeriodicity {
            reasons.append(String(format: "Weak periodicity (%.2f).", periodicity))
        } else if periodicity == nil {
            reasons.append("Periodicity could not be estimated.")
        }
        if let period = dominantPeriodS, !intervals.isEmpty {
            let medianS = Statistics.median(intervals.map { $0.endTime - $0.startTime })
            if abs(medianS - period) / period > requirements.maxPeriodMismatch {
                reasons.append(String(format: "Median detected interval (%.0f ms) disagrees with the dominant signal period (%.0f ms): possible double or missed detections.", medianS * 1000, period * 1000))
            }
        }
        if unreliableFraction > requirements.maxUnreliableFraction {
            reasons.append(String(format: "%.0f%% of the recording is motion artifact or sampling gap.", unreliableFraction * 100))
        }
        var s = IntervalSummary(intervalCount: intervals.count, acceptedCount: accepted.count, acceptedFraction: fraction,
                                reliability: reasons.isEmpty ? .sufficient : .insufficient(reasons))
        guard reasons.isEmpty else { return s }
        let ms = accepted.map(\.milliseconds)
        let mean = Statistics.mean(ms)
        s.meanIntervalMs = mean
        s.meanRateBPM = 60_000 / mean
        s.sdMs = Statistics.sampleStd(ms)
        var diffs = [Double]()
        for i in 1..<intervals.count where intervals[i].isAccepted && intervals[i - 1].isAccepted
            && intervals[i].startTime == intervals[i - 1].endTime {
            let d = intervals[i].milliseconds - intervals[i - 1].milliseconds
            diffs.append(d * d)
        }
        s.rmssdMs = diffs.isEmpty ? nil : (diffs.reduce(0, +) / Double(diffs.count)).squareRoot()
        return s
    }
}
