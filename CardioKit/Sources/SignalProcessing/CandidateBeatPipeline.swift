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
        let startTime = raw.startTime
        let intervals = BeatIntervals.compute(beatTimes: peaks.map(\.time), config: config.intervals) { a, b in
            let i0 = max(0, Int(((a - startTime) * fs).rounded(.down)))
            let i1 = min(excluded.count - 1, Int(((b - startTime) * fs).rounded(.up)))
            return i0 <= i1 && excluded[i0...i1].contains(true)
        }
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
        let periodicity = auto?.value
        let excludedFraction = excluded.isEmpty ? 0 : Double(excluded.filter { $0 }.count) / Double(excluded.count)
        let summary = IntervalSummary.summarize(intervals, periodicity: periodicity, dominantPeriodS: auto?.lagS,
                                                unreliableFraction: excludedFraction, requirements: config.requirements)
        return Result(raw: raw, filtered: filtered, envelope: envelope, excluded: excluded, peaks: peaks,
                      intervals: intervals, periodicity: periodicity, dominantPeriodS: auto?.lagS, summary: summary)
    }
}
