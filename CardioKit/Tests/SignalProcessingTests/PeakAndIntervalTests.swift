import CardioCore
import XCTest
@testable import SignalProcessing

final class PeakDetectionTests: XCTestCase {
    let fs = 100.0

    /// Gaussian bumps at given times (seconds) with given amplitudes.
    private func bumps(_ times: [Double], amplitudes: [Double]? = nil, width: Double = 0.03, duration: Double = 10) -> [Double] {
        (0..<Int(duration * fs)).map { i in
            let t = Double(i) / fs
            return times.enumerated().reduce(0) { acc, e in
                acc + (amplitudes?[e.offset] ?? 1) * exp(-0.5 * pow((t - e.element) / width, 2))
            }
        }
    }

    func testFindsAllPeaksWithSubSampleTiming() {
        let truth = [1.003, 2.017, 3.0, 4.555, 5.21]
        let peaks = PeakDetector.detect(bumps(truth), sampleRateHz: fs, startTime: 0, config: .init())
        XCTAssertEqual(peaks.count, truth.count)
        for (p, t) in zip(peaks, truth) { XCTAssertEqual(p.time, t, accuracy: 0.0015) }
    }

    func testStartTimeOffsetsPeakTimes() {
        let peaks = PeakDetector.detect(bumps([1, 2]), sampleRateHz: fs, startTime: 500, config: .init())
        XCTAssertEqual(peaks.map(\.time), [501, 502].map(Double.init), accuracy: 1e-6)
    }

    func testRefractoryPeriodSuppressesSecondaryComponent() {
        // Main peak at 1.0 s followed by a weaker secondary component 0.25 s later, every cycle.
        let mains = [1.0, 2.0, 3.0, 4.0]
        let x = bumps(mains + mains.map { $0 + 0.25 }, amplitudes: [1, 1, 1, 1, 0.8, 0.8, 0.8, 0.8])
        let strict = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0, config: .init(refractoryS: 0.3))
        XCTAssertEqual(strict.map(\.time), mains, accuracy: 0.002)
        let loose = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0, config: .init(refractoryS: 0.1))
        XCTAssertEqual(loose.count, 8, "without a sufficient refractory period both components are reported")
    }

    func testRefractoryKeepsStrongerOfTwoClosePeaks() {
        let x = bumps([1.0, 1.15], amplitudes: [0.6, 1.0])
        let peaks = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0, config: .init(refractoryS: 0.3))
        XCTAssertEqual(peaks.count, 1)
        XCTAssertEqual(peaks[0].time, 1.15, accuracy: 0.01)
    }

    func testLocalMaxThresholdIgnoresSmallPeaks() {
        let x = bumps([1, 2, 3, 4], amplitudes: [1, 0.2, 1, 1])
        let peaks = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0,
                                        config: .init(threshold: .fractionOfLocalMax(fraction: 0.35, windowS: 3)))
        XCTAssertEqual(peaks.map(\.time), [1, 3, 4], accuracy: 0.002)
    }

    func testLocalMaxThresholdAdaptsToAmplitudeDrift() {
        // Amplitude falls 10x over the record; a global threshold would lose the late beats.
        let times = (1...9).map(Double.init)
        let amps = times.map { 1.0 - 0.1 * ($0 - 1) * 1.125 }
        let peaks = PeakDetector.detect(bumps(times, amplitudes: amps), sampleRateHz: fs, startTime: 0,
                                        config: .init(threshold: .fractionOfLocalMax(fraction: 0.35, windowS: 2)))
        XCTAssertEqual(peaks.count, 9)
    }

    func testExcludedSamplesProduceNoPeaks() {
        let x = bumps([1, 2, 3])
        var exclude = [Bool](repeating: false, count: x.count)
        for i in 180..<220 { exclude[i] = true }
        let peaks = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0, config: .init(), exclude: exclude)
        XCTAssertEqual(peaks.map(\.time), [1, 3], accuracy: 0.002)
    }

    func testRobustZThreshold() {
        var x = [Double](repeating: 0, count: 500)
        for i in x.indices { x[i] = 0.01 * sin(Double(i)) }
        x[100] = 1; x[300] = 1
        let peaks = PeakDetector.detect(x, sampleRateHz: fs, startTime: 0, config: .init(threshold: .robustZ(k: 6)))
        XCTAssertEqual(peaks.map(\.index), [100, 300])
    }
}

final class BeatIntervalTests: XCTestCase {
    func testIntervalsInMilliseconds() {
        let iv = BeatIntervals.compute(beatTimes: [10.0, 10.7, 11.35, 12.05])
        XCTAssertEqual(iv.map(\.milliseconds), [700, 650, 700], accuracy: 1e-6)
        XCTAssertTrue(iv.allSatisfy(\.isAccepted))
    }

    func testMissedBeatProducesFlaggedLongInterval() {
        var beats = (0..<20).map { Double($0) * 0.7 }
        beats.remove(at: 10)
        let iv = BeatIntervals.compute(beatTimes: beats)
        let flagged = iv.filter { !$0.isAccepted }
        XCTAssertEqual(flagged.count, 1)
        XCTAssertEqual(flagged[0].milliseconds, 1400, accuracy: 1e-6)
        XCTAssertTrue(flagged[0].flags.contains(.abruptChange))
    }

    func testDoubleDetectionProducesFlaggedShortIntervals() {
        var beats = (0..<20).map { Double($0) * 0.7 }
        beats.insert(7.0 + 0.25, at: 11)
        let iv = BeatIntervals.compute(beatTimes: beats)
        XCTAssertEqual(iv.filter { !$0.isAccepted }.count, 2)
    }

    func testPhysiologicalRange() {
        let iv = BeatIntervals.compute(beatTimes: [0, 0.2, 2.5])
        XCTAssertTrue(iv[0].flags.contains(.outOfRange))
        XCTAssertTrue(iv[1].flags.contains(.outOfRange))
    }

    func testRespiratoryModulationIsNotFlagged() {
        // +/-20 % sinusoidal modulation should pass with the default 35 % tolerance.
        var t = 0.0
        var beats = [Double]()
        while t < 60 { beats.append(t); t += 0.8 * (1 + 0.2 * sin(2 * .pi * 0.25 * t)) }
        let iv = BeatIntervals.compute(beatTimes: beats)
        XCTAssertTrue(iv.allSatisfy(\.isAccepted))
    }

    func testUnreliableSegmentFlag() {
        let iv = BeatIntervals.compute(beatTimes: [0, 0.7, 1.4, 2.1]) { a, _ in a == 0.7 }
        XCTAssertEqual(iv.map { $0.flags.contains(.unreliableSegment) }, [false, true, false])
    }

    func testSummaryStatistics() {
        // Alternating 600/800 ms: mean 700, SD (n-1), RMSSD = 200.
        var beats = [0.0]
        for i in 0..<20 { beats.append(beats.last! + (i % 2 == 0 ? 0.6 : 0.8)) }
        var cfg = BeatIntervalConfig()
        cfg.maxRelativeDeviation = 0.5
        let iv = BeatIntervals.compute(beatTimes: beats, config: cfg)
        let s = IntervalSummary.summarize(iv, periodicity: 0.9, unreliableFraction: 0)
        XCTAssertTrue(s.isReliable)
        XCTAssertEqual(s.meanIntervalMs!, 700, accuracy: 1e-6)
        XCTAssertEqual(s.meanRateBPM!, 60_000 / 700, accuracy: 1e-6)
        XCTAssertEqual(s.rmssdMs!, 200, accuracy: 1e-6)
        XCTAssertEqual(s.sdMs!, 100 * (20.0 / 19).squareRoot(), accuracy: 1e-6)
    }

    func testSummaryWithholdsValuesWhenUnreliable() {
        let iv = BeatIntervals.compute(beatTimes: [0, 0.7, 1.4, 2.1])
        let s = IntervalSummary.summarize(iv, periodicity: 0.9, unreliableFraction: 0)
        XCTAssertFalse(s.isReliable)
        XCTAssertNil(s.meanRateBPM)
        XCTAssertNil(s.rmssdMs)

        let many = BeatIntervals.compute(beatTimes: (0..<30).map { Double($0) * 0.7 })
        XCTAssertFalse(IntervalSummary.summarize(many, periodicity: 0.1, unreliableFraction: 0).isReliable)
        XCTAssertFalse(IntervalSummary.summarize(many, periodicity: 0.9, unreliableFraction: 0.5).isReliable)
        XCTAssertTrue(IntervalSummary.summarize(many, periodicity: 0.9, unreliableFraction: 0).isReliable)
    }
}

final class BeatMatcherTests: XCTestCase {
    func testCountsAndTiming() {
        let ref = [1.0, 2.0, 3.0, 4.0, 5.0]
        let det = [1.01, 2.02, 3.5, 4.0, 5.0, 5.3]       // 3.0 missed, 3.5 and 5.3 false
        let r = BeatMatcher.match(detected: det, reference: ref, toleranceS: 0.1)
        XCTAssertEqual(r.truePositives, 4)
        XCTAssertEqual(r.falseNegatives, 1)
        XCTAssertEqual(r.falsePositives, 2)
        XCTAssertEqual(r.sensitivity, 0.8, accuracy: 1e-12)
        XCTAssertEqual(r.positivePredictiveValue, 4.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(r.intervalErrorsMs, [10, 0], accuracy: 1e-6)
    }

    func testOffsetCompensation() {
        let ref = [1.0, 2.0, 3.0]
        let r = BeatMatcher.match(detected: ref.map { $0 + 0.15 }, reference: ref, toleranceS: 0.05, offsetS: 0.15)
        XCTAssertEqual(r.truePositives, 3)
    }
}

func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "count", file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
