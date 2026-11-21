import CardioCore
import XCTest
import SignalProcessing
import SyntheticData

/// End-to-end validation of the *candidate* beat pipeline on SYNTHETIC data with known ground
/// truth. Passing these tests shows the processing behaves as designed on the synthetic model;
/// it says nothing about accuracy on real dogs (that requires a simultaneous ECG reference,
/// see docs/VALIDATION.md).
final class SyntheticValidationTests: XCTestCase {
    private func run(_ s: SyntheticScenario, config: CandidateBeatPipeline.Config = .init()) throws -> ScenarioOutcome {
        let o = try evaluate(s.generate(), config: config)
        print("[validation] " + o.line)
        return o
    }

    private func truthRateBPM(_ rec: SyntheticRecording) -> Double {
        60_000 / Statistics.mean(rec.truthIntervalsMs)
    }

    func testRegularRhythm() throws {
        let o = try run(.regular)
        XCTAssertGreaterThanOrEqual(o.match.sensitivity, 0.98)
        XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.98)
        XCTAssertLessThan(o.match.medianAbsIntervalErrorMs, 3)
        XCTAssertLessThan(abs(o.match.meanTimingErrorS), 0.015)
        XCTAssertTrue(o.result.summary.isReliable)
        XCTAssertEqual(o.result.summary.meanRateBPM!, truthRateBPM(o.truth), accuracy: 1.5)
    }

    func testRespiratorySinusArrhythmiaIsTrackedNotRejected() throws {
        let o = try run(.respiratorySinusArrhythmia)
        XCTAssertGreaterThanOrEqual(o.match.sensitivity, 0.98)
        XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.98)
        XCTAssertTrue(o.result.summary.isReliable, "respiratory modulation must not be treated as unreliable")
        XCTAssertLessThan(o.match.medianAbsIntervalErrorMs, 3)
        XCTAssertLessThan(o.match.intervalErrorsMs.map(abs).max()!, 20)
        // The detected interval series must reproduce the modulation depth.
        let truthSD = Statistics.std(o.truth.truthIntervalsMs)
        XCTAssertEqual(o.result.summary.sdMs!, truthSD, accuracy: 0.1 * truthSD)
    }

    func testPrematureAndMissedBeatsAreFlagged() throws {
        let o = try run(.prematureAndMissingBeats)
        XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.98)
        XCTAssertGreaterThanOrEqual(o.match.sensitivity, 0.95)
        // Every interval far from the typical value (missed beat, premature beat or its pause) must be flagged.
        let median = Statistics.median(o.result.intervals.map(\.milliseconds))
        for iv in o.result.intervals where abs(iv.milliseconds - median) > 0.35 * median {
            XCTAssertFalse(iv.isAccepted, "unflagged anomalous interval \(iv.milliseconds) ms")
        }
        XCTAssertGreaterThanOrEqual(o.result.intervals.filter { !$0.isAccepted }.count, 5)
    }

    func testMotionArtifactsAreExcluded() throws {
        let o = try run(.motionArtifacts)
        let spans = o.truth.artifactSpans
        let fs = o.result.raw.sampleRateHz
        for span in spans {
            // No beats reported inside an artifact.
            XCTAssertFalse(o.result.beatTimes.contains { span.contains($0) }, "detection inside artifact \(span)")
            // The exclusion mask covers the artifact.
            let i0 = Int((span.lowerBound - o.result.raw.startTime) * fs), i1 = Int((span.upperBound - o.result.raw.startTime) * fs)
            let covered = o.result.excluded[i0...i1].filter { $0 }.count
            XCTAssertGreaterThan(Double(covered) / Double(i1 - i0 + 1), 0.9)
        }
        // Outside artifacts, detection is unaffected.
        let clean: (Double) -> Bool = { t in !spans.contains { ($0.lowerBound - 0.6)...($0.upperBound + 0.6) ~= t } }
        let m = BeatMatcher.match(detected: o.result.beatTimes.filter(clean), reference: o.truth.beatTimes.filter(clean))
        XCTAssertGreaterThanOrEqual(m.sensitivity, 0.98)
        XCTAssertGreaterThanOrEqual(m.positivePredictiveValue, 0.98)
        XCTAssertTrue(o.result.intervals.contains { $0.flags.contains(.unreliableSegment) })
    }

    func testLowSNRReportsInsufficientConfidence() throws {
        let o = try run(.lowSNR)
        XCTAssertFalse(o.result.summary.isReliable)
        XCTAssertNil(o.result.summary.meanRateBPM, "no rate may be reported without adequate confidence")
    }

    func testDoublePeaksDoNotProduceFalseConfidence() throws {
        // Default configuration: components are nearly equal, so identification is ambiguous.
        let o = try run(.doublePeaks)
        if o.result.summary.isReliable {
            XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.95)
        }
        // Too-short refractory period: every cycle is detected twice. This once produced a
        // "reliable" 181 beats/min; the period-consistency check must catch it.
        var loose = CandidateBeatPipeline.Config()
        loose.peaks.refractoryS = 0.1
        let doubled = try run(.doublePeaks, config: loose)
        XCTAssertGreaterThan(doubled.result.peaks.count, Int(1.8 * Double(doubled.truth.beatTimes.count)))
        XCTAssertFalse(doubled.result.summary.isReliable)
        XCTAssertNil(doubled.result.summary.meanRateBPM)
    }

    func testSamplingJitterAndDroppedSamples() throws {
        let rec = SyntheticScenario.jitterAndDroppedSamples.generate()
        let stats = SamplingStatistics.compute(timestamps: rec.accelerometer.timestamps)
        XCTAssertGreaterThan(stats.gapCount, 10)
        XCTAssertGreaterThan(stats.stdIntervalS!, 0.002)
        let o = try run(.jitterAndDroppedSamples)
        XCTAssertGreaterThanOrEqual(o.match.sensitivity, 0.98)
        XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.98)
        XCTAssertLessThan(o.match.medianAbsIntervalErrorMs, 3)
    }

    /// Core safety property: whenever the pipeline claims sufficient reliability, the result
    /// must actually be accurate. Checked on every scenario with several noise seeds.
    func testReliableImpliesAccurateAcrossScenariosAndSeeds() throws {
        var reliableCount = 0
        for scenario in SyntheticScenario.allCases {
            for seed in [11, 23, 37] as [UInt64] {
                var c = scenario.config
                c.seed = seed
                let rec = SyntheticGenerator.generate(c, name: "\(scenario.rawValue)#\(seed)")
                let o = try evaluate(rec)
                guard o.result.summary.isReliable else { continue }
                reliableCount += 1
                XCTAssertGreaterThanOrEqual(o.match.positivePredictiveValue, 0.95, o.line)
                XCTAssertEqual(o.result.summary.meanRateBPM!, truthRateBPM(rec), accuracy: 3, o.line)
            }
        }
        XCTAssertGreaterThan(reliableCount, 10, "the gate should not simply reject everything")
    }
}
