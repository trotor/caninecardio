import CardioCore
import Foundation

/// Experimental, configurable pipeline producing *candidate* mechanical beats from one
/// accelerometer axis. Nothing here is validated against a reference; results must be scored
/// (see `BeatMatcher`) before being trusted.
///
/// Steps: resample to a uniform grid -> linear detrend -> zero-phase Butterworth band-pass ->
/// RMS envelope -> artifact mask -> peak detection with refractory period -> interval plausibility
/// flags -> reliability summary.
public struct CandidateBeatPipeline: Sendable {
    public struct Config: Sendable, Equatable {
        public var axis: MotionAxis = .z
        public var resampleRateHz: Double = 100
        public var band: FrequencyBand = .cardiacVibration
        public var filterOrder: Int = 2
        public var envelopeWindowS: Double = 0.06
        public var periodicitySmoothingS: Double = 0.3
        public var peaks = PeakDetectionConfig()
        public var intervals = BeatIntervalConfig()
        public var artifacts = MotionArtifactConfig()
        /// Broadband filter applied before artifact detection.
        public var artifactBand = FrequencyBand(name: "Artifact 0.5–30 Hz", lowHz: 0.5, highHz: 30)
        public var requirements = IntervalSummary.Requirements()
        public init() {}
    }

    public struct Result: Sendable {
        public var raw: UniformSignal
        public var filtered: [Double]
        public var envelope: [Double]
        /// true where samples are excluded (motion artifact or sampling gap).
        public var excluded: [Bool]
        public var peaks: [Peak]
        public var intervals: [BeatInterval]
        public var periodicity: Double?
        public var dominantPeriodS: Double?
        public var summary: IntervalSummary

        public var beatTimes: [Double] { peaks.map(\.time) }
        public var excludedFraction: Double {
            excluded.isEmpty ? 0 : Double(excluded.filter { $0 }.count) / Double(excluded.count)
        }
    }

    public var config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    public func run(_ series: MotionSeries) throws -> Result {
        let raw = Resampler.linear(times: series.timestamps, values: series.values(config.axis),
                                   rateHz: config.resampleRateHz)
        return try run(raw)
    }

    public func run(_ raw: UniformSignal) throws -> Result {
        let fs = raw.sampleRateHz
        let detrended = Detrend.linear(raw.values)
        let filter = try config.band.filter(order: config.filterOrder, sampleRateHz: fs)
        let filtered = filter.filtfilt(detrended, padLength: config.band.padLength(sampleRateHz: fs))
        let envelope = Envelope.rms(filtered, sampleRateHz: fs, windowS: config.envelopeWindowS)

        let broadband = try config.artifactBand.filter(order: 2, sampleRateHz: fs)
            .filtfilt(detrended, padLength: config.artifactBand.padLength(sampleRateHz: fs))
        var excluded = MotionArtifactDetector.mask(broadband, sampleRateHz: fs, config: config.artifacts)
        for i in excluded.indices where !raw.valid[i] { excluded[i] = true }

        let peaks = PeakDetector.detect(envelope, sampleRateHz: fs, startTime: raw.startTime,
                                        config: config.peaks, exclude: excluded)
        // Periodicity of the envelope over plausible beat periods (30-240 beats/min),
        // computed on a smoothed envelope so that small beat-to-beat variation is tolerated.
        // The 0.3 s smoothing merges the mechanical components of one cycle into a single hump.
        // Excluded segments (artifacts, gaps) are replaced by the median so they cannot dominate.
        var forPeriodicity = envelope
        let included = envelope.indices.filter { !excluded[$0] }.map { envelope[$0] }
        let fill = included.isEmpty ? 0 : Statistics.median(included)
        for i in forPeriodicity.indices where excluded[i] { forPeriodicity[i] = fill }
        let smooth = Envelope.rms(forPeriodicity, sampleRateHz: fs, windowS: config.periodicitySmoothingS)
        let auto = Periodicity.autocorrelationPeak(smooth, sampleRateHz: fs, minLagS: 0.25, maxLagS: 2.0)
        var result = Result(raw: raw, filtered: filtered, envelope: envelope, excluded: excluded, peaks: peaks,
                            intervals: [], periodicity: auto?.value, dominantPeriodS: auto?.lagS,
                            summary: IntervalSummary.summarize([], periodicity: nil, unreliableFraction: 0))
        (result.intervals, result.summary) = result.evaluate(beatTimes: peaks.map(\.time), config: config)
        return result
    }
}

extension CandidateBeatPipeline.Result {
    /// Intervals and reliability summary for an arbitrary set of beat times (for example the
    /// detected beats after manual corrections), using this result's artifact mask and periodicity.
    public func evaluate(beatTimes: [Double], config: CandidateBeatPipeline.Config) -> ([BeatInterval], IntervalSummary) {
        let fs = raw.sampleRateHz
        let start = raw.startTime
        let mask = excluded
        let intervals = BeatIntervals.compute(beatTimes: beatTimes.sorted(), config: config.intervals) { a, b in
            guard !mask.isEmpty else { return false }
            let i0 = min(mask.count - 1, max(0, Int(((a - start) * fs).rounded(.down))))
            let i1 = min(mask.count - 1, max(0, Int(((b - start) * fs).rounded(.up))))
            return i0 <= i1 && mask[i0...i1].contains(true)
        }
        let summary = IntervalSummary.summarize(intervals, periodicity: periodicity, dominantPeriodS: dominantPeriodS,
                                                unreliableFraction: excludedFraction, requirements: config.requirements)
        return (intervals, summary)
    }

    /// Time of the envelope maximum within `windowS` of `time`, for placing a manually added beat.
    public func nearestEnvelopePeak(to time: Double, windowS: Double = 0.15) -> Double? {
        let fs = raw.sampleRateHz
        let centre = Int(((time - raw.startTime) * fs).rounded())
        let half = Int(windowS * fs)
        let lo = max(0, centre - half), hi = min(envelope.count - 1, centre + half)
        guard lo <= hi else { return nil }
        let best = (lo...hi).max { envelope[$0] < envelope[$1] }!
        return raw.time(at: Double(best))
    }
}

/// Manual corrections to automatically detected beats. Times are on the uptime clock.
public struct BeatEdits: Codable, Sendable, Equatable {
    /// Detected beats the operator rejected.
    public var removed: [Double] = []
    /// Beats the operator added.
    public var added: [Double] = []

    public init(removed: [Double] = [], added: [Double] = []) {
        self.removed = removed
        self.added = added
    }

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    /// Detected beats minus rejected ones, plus added ones, sorted.
    public func apply(to detected: [Double], toleranceS: Double = 0.02) -> [Double] {
        let kept = detected.filter { d in !removed.contains { abs($0 - d) <= toleranceS } }
        return (kept + added).sorted()
    }

    /// Toggles the edit nearest to `time`: un-rejects a rejected beat, deletes an added beat,
    /// rejects a detected beat, or otherwise adds a beat at `addAt` (if given).
    public mutating func toggle(near time: Double, detected: [Double], addAt: Double?, toleranceS: Double = 0.12) {
        func nearest(_ list: [Double]) -> Int? {
            list.indices.filter { abs(list[$0] - time) <= toleranceS }.min { abs(list[$0] - time) < abs(list[$1] - time) }
        }
        if let i = nearest(added) {
            added.remove(at: i)
        } else if let i = nearest(removed) {
            removed.remove(at: i)
        } else if let i = nearest(detected) {
            removed.append(detected[i])
        } else if let addAt {
            added.append(addAt)
        }
    }
}

extension CandidateBeatPipeline {
    /// Picks the axis to present: reliable results first, then the strongest envelope periodicity.
    public static func chooseAxis(_ results: [MotionAxis: Result]) -> MotionAxis? {
        results.max { a, b in
            let ra = a.value.summary.isReliable, rb = b.value.summary.isReliable
            if ra != rb { return !ra }
            return (a.value.periodicity ?? -1) < (b.value.periodicity ?? -1)
        }?.key
    }
}
