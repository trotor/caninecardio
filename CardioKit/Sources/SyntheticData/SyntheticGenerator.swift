import CardioCore
import Foundation

// SYNTHETIC DATA — for automated tests, previews and documentation only.
// The waveform model is a crude, hand-made approximation of chest-wall vibration. It is NOT a
// validated model of canine cardiac mechanics and must never be presented as a measurement.

/// Deterministic pseudo-random numbers (SplitMix64) so synthetic datasets are reproducible.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }

    /// Standard normal (Box-Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

public struct SyntheticConfig: Sendable {
    public var durationS: Double = 60
    public var sampleRateHz: Double = 100
    public var startUptimeS: Double = 1000

    // Cardiac timing
    public var meanHeartRateBPM: Double = 90
    /// Respiratory sinus arrhythmia: fractional modulation of the beat interval.
    /// 0.15 means intervals vary by about +/-15 % over each breath.
    public var rsaDepth: Double = 0
    public var respirationRateBPM: Double = 20

    // Cardiac waveform (z axis; x/y get `crossAxisFraction` of it)
    public var cardiacAmplitudeG: Double = 0.004
    /// Second mechanical component per cycle (aortic-closure-like), relative amplitude.
    public var secondComponentRatio: Double = 0.5
    public var secondComponentDelayS: Double = 0.28
    public var burstFrequencyHz: Double = 14
    public var burstWidthS: Double = 0.025
    public var crossAxisFraction: Double = 0.3

    // Other components
    public var respirationAmplitudeG: Double = 0.003
    public var noiseStdG: Double = 0.0004
    public var gravity: (x: Double, y: Double, z: Double) = (0.02, -0.05, -0.998)

    // Anomalies
    /// Beat indices that exist in the ground truth but have 5 % amplitude (likely missed).
    public var weakBeatIndices: Set<Int> = []
    /// Beat indices that occur early (at 60 % of the expected interval), followed by a
    /// compensatory pause.
    public var prematureBeatIndices: Set<Int> = []
    public var motionArtifacts: [MotionArtifact] = []

    // Sampling imperfections
    /// Standard deviation of the actual sampling instants around the nominal grid (timestamps
    /// report the actual instants).
    public var timestampJitterStdS: Double = 0
    /// Probability that an individual sample is dropped.
    public var dropProbability: Double = 0
    /// Explicit dropped spans (start, duration) in seconds from the start.
    public var droppedSpans: [(Double, Double)] = []

    public var seed: UInt64 = 1

    public struct MotionArtifact: Sendable, Equatable {
        public var startS: Double
        public var durationS: Double
        public var amplitudeG: Double
        public init(startS: Double, durationS: Double, amplitudeG: Double) {
            self.startS = startS; self.durationS = durationS; self.amplitudeG = amplitudeG
        }
    }

    public init() {}
}

public struct SyntheticRecording: Sendable {
    public var name: String
    public var description: String
    public var config: SyntheticConfig
    public var accelerometer: MotionSeries
    /// Ground-truth times (uptime seconds) of the first mechanical component of each beat.
    public var beatTimes: [Double]
    /// Ground-truth artifact spans (uptime seconds).
    public var artifactSpans: [ClosedRange<Double>]

    public var truthIntervalsMs: [Double] { zip(beatTimes, beatTimes.dropFirst()).map { ($1 - $0) * 1000 } }
}

public enum SyntheticGenerator {
    public static func beatTimes(_ c: SyntheticConfig) -> [Double] {
        let baseInterval = 60 / c.meanHeartRateBPM
        let fResp = c.respirationRateBPM / 60
        var times = [Double]()
        var t = 0.3
        var k = 0
        while t < c.durationS - 0.3 {
            times.append(t)
            // RSA: shorter intervals (faster rate) during inspiration.
            var interval = baseInterval * (1 - c.rsaDepth * sin(2 * .pi * fResp * t))
            if c.prematureBeatIndices.contains(k + 1) {
                interval *= 0.6
            } else if c.prematureBeatIndices.contains(k) {
                interval *= 1.4                        // compensatory pause
            }
            t += interval
            k += 1
        }
        return times.map { $0 + c.startUptimeS }
    }

    public static func generate(_ c: SyntheticConfig, name: String = "synthetic", description: String = "") -> SyntheticRecording {
        var rng = SeededRandom(seed: c.seed)
        let beats = beatTimes(c)
        let t0 = c.startUptimeS
        let n = Int(c.durationS * c.sampleRateHz)
        let fResp = c.respirationRateBPM / 60
        let artifactPhases = c.motionArtifacts.map { _ in (rng.uniform() * 2 * .pi, 1 + 3 * rng.uniform()) }

        func burst(_ dt: Double) -> Double {
            let g = exp(-0.5 * (dt / c.burstWidthS) * (dt / c.burstWidthS))
            return g * sin(2 * .pi * c.burstFrequencyHz * dt)
        }

        var samples = [Vector3Sample]()
        samples.reserveCapacity(n)
        var beatCursor = 0
        for i in 0..<n {
            let nominal = Double(i) / c.sampleRateHz
            let rel = nominal + (c.timestampJitterStdS > 0 ? c.timestampJitterStdS * rng.gaussian() : 0)
            let drop = c.dropProbability > 0 && rng.uniform() < c.dropProbability
            let t = t0 + rel

            var cardiac = 0.0
            while beatCursor < beats.count && beats[beatCursor] < t - 1 { beatCursor += 1 }
            var b = beatCursor
            while b < beats.count && beats[b] < t + 0.2 {
                let amp = c.weakBeatIndices.contains(b) ? 0.05 : 1
                let dt = t - beats[b]
                cardiac += amp * (burst(dt) + c.secondComponentRatio * burst(dt - c.secondComponentDelayS))
                b += 1
            }
            cardiac *= c.cardiacAmplitudeG

            var artifact = (0.0, 0.0, 0.0)
            for (k, a) in c.motionArtifacts.enumerated() where rel >= a.startS && rel <= a.startS + a.durationS {
                let u = (rel - a.startS) / a.durationS
                let window = sin(.pi * u) * sin(.pi * u)
                let (phase, freq) = artifactPhases[k]
                let v = a.amplitudeG * window * sin(2 * .pi * freq * rel + phase)
                artifact = (0.6 * v + 0.2 * a.amplitudeG * window * rng.gaussian(),
                            0.8 * v, v + 0.2 * a.amplitudeG * window * rng.gaussian())
            }
            let resp = c.respirationAmplitudeG * sin(2 * .pi * fResp * rel)

            guard !drop, !c.droppedSpans.contains(where: { rel >= $0.0 && rel < $0.0 + $0.1 }) else { continue }
            samples.append(Vector3Sample(
                t: t,
                x: c.gravity.x + c.crossAxisFraction * cardiac + 0.3 * resp + artifact.0 + c.noiseStdG * rng.gaussian(),
                y: c.gravity.y + c.crossAxisFraction * cardiac + 0.5 * resp + artifact.1 + c.noiseStdG * rng.gaussian(),
                z: c.gravity.z + cardiac + resp + artifact.2 + c.noiseStdG * rng.gaussian(),
                receivedAt: t + 0.01))
        }
        samples.sort { $0.t < $1.t }
        let spans = c.motionArtifacts.map { (t0 + $0.startS)...(t0 + $0.startS + $0.durationS) }
        return SyntheticRecording(name: name, description: description, config: c,
                                  accelerometer: MotionSeries(kind: .accelerometer, samples: samples),
                                  beatTimes: beats, artifactSpans: spans)
    }
}

/// Named validation scenarios required by the project specification.
public enum SyntheticScenario: String, CaseIterable, Sendable {
    case regular
    case respiratorySinusArrhythmia
    case prematureAndMissingBeats
    case motionArtifacts
    case lowSNR
    case doublePeaks
    case jitterAndDroppedSamples

    public var summary: String {
        switch self {
        case .regular: "Regular 90 beats/min, no respiratory modulation."
        case .respiratorySinusArrhythmia: "75 beats/min with ±18 % interval modulation at 15 breaths/min."
        case .prematureAndMissingBeats: "Two premature beats with compensatory pauses and three very weak (likely undetectable) beats."
        case .motionArtifacts: "Regular beats with three large motion bursts (dog shifting)."
        case .lowSNR: "Cardiac vibration buried in broadband noise (noise RMS ≈ 3× cardiac peak amplitude)."
        case .doublePeaks: "Second mechanical component almost as strong as the first in every cycle."
        case .jitterAndDroppedSamples: "2 ms timestamp jitter, 3 % random sample drops and two 150 ms gaps."
        }
    }

    public var config: SyntheticConfig {
        var c = SyntheticConfig()
        c.seed = UInt64(SyntheticScenario.allCases.firstIndex(of: self)! + 1)
        switch self {
        case .regular:
            break
        case .respiratorySinusArrhythmia:
            c.meanHeartRateBPM = 75
            c.rsaDepth = 0.18
            c.respirationRateBPM = 15
        case .prematureAndMissingBeats:
            c.prematureBeatIndices = [20, 55]
            c.weakBeatIndices = [35, 70, 71]
        case .motionArtifacts:
            c.motionArtifacts = [.init(startS: 12, durationS: 2, amplitudeG: 0.08),
                                 .init(startS: 30, durationS: 1.5, amplitudeG: 0.15),
                                 .init(startS: 47, durationS: 3, amplitudeG: 0.05)]
        case .lowSNR:
            c.noiseStdG = 0.012
        case .doublePeaks:
            c.secondComponentRatio = 0.95
        case .jitterAndDroppedSamples:
            c.timestampJitterStdS = 0.002
            c.dropProbability = 0.03
            c.droppedSpans = [(20, 0.15), (41, 0.15)]
        }
        return c
    }

    public func generate() -> SyntheticRecording {
        SyntheticGenerator.generate(config, name: rawValue, description: summary)
    }
}
