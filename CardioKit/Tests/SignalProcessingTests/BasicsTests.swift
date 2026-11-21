import CardioCore
import XCTest
@testable import SignalProcessing

final class BasicsTests: XCTestCase {
    func testLinearDetrendRemovesLineExactly() {
        let x = (0..<100).map { 3.0 + 0.25 * Double($0) }
        for v in Detrend.linear(x) { XCTAssertEqual(v, 0, accuracy: 1e-9) }
    }

    func testRemoveMean() {
        XCTAssertEqual(Detrend.removeMean([1, 2, 3]), [-1, 0, 1])
    }

    func testResamplerInterpolatesIrregularTimestamps() {
        // Irregular samples of a straight line must resample onto the same line.
        let times = [0.0, 0.009, 0.021, 0.030, 0.041, 0.049, 0.060]
        let values = times.map { 2 * $0 + 1 }
        let u = Resampler.linear(times: times, values: values, rateHz: 100)
        XCTAssertEqual(u.count, 7)
        for (i, v) in u.values.enumerated() { XCTAssertEqual(v, 2 * Double(i) / 100 + 1, accuracy: 1e-12) }
        XCTAssertTrue(u.valid.allSatisfy { $0 })
    }

    func testResamplerMarksLongGapsInvalid() {
        var times = (0..<100).map { Double($0) / 100 }
        times.removeSubrange(40..<55)                       // 160 ms gap
        let u = Resampler.linear(times: times, values: times.map { sin($0) }, rateHz: 100)
        XCTAssertEqual(u.count, 100)
        XCTAssertFalse(u.valid[45])
        XCTAssertTrue(u.valid[10])
        XCTAssertTrue(u.valid[80])
    }

    func testRMSEnvelopeOfSine() {
        let fs = 100.0
        let x = (0..<1000).map { sin(2 * .pi * 10 * Double($0) / fs) }
        let env = Envelope.rms(x, sampleRateHz: fs, windowS: 0.1)
        XCTAssertEqual(env[500], 1 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testPeriodicityHighForPulseTrainLowForNoise() {
        let fs = 100.0
        let pulses = (0..<3000).map { i in i % 70 < 5 ? 1.0 : 0.0 }
        let p = Periodicity.autocorrelationPeak(pulses, sampleRateHz: fs, minLagS: 0.25, maxLagS: 2)!
        XCTAssertGreaterThan(p.value, 0.9)
        XCTAssertEqual(p.lagS, 0.7, accuracy: 0.011)

        var rng = SystemRandomNumberGenerator()
        let noise = (0..<3000).map { _ in Double.random(in: -1...1, using: &rng) }
        XCTAssertLessThan(Periodicity.autocorrelationPeak(noise, sampleRateHz: fs, minLagS: 0.25, maxLagS: 2)!.value, 0.2)
    }

    /// Regression: a recording dominated by gross motion crashed the app when every local
    /// maximum of the autocorrelation in the lag range was negative (threshold 0.85 x a negative
    /// maximum is larger than the maximum itself, so no lag qualified).
    func testPeriodicityWithOnlyNegativeLocalMaximaDoesNotCrash() throws {
        let fs = 100.0
        // Slow 3 s oscillation (negative autocorrelation for lags 1-2 s) plus a 0.5 s ripple
        // that creates local maxima there.
        let x = (0..<3000).map { i -> Double in
            let t = Double(i) / fs
            return sin(2 * .pi * t / 3) + 0.5 * sin(2 * .pi * t / 0.5)
        }
        let p = try XCTUnwrap(Periodicity.autocorrelationPeak(x, sampleRateHz: fs, minLagS: 1.0, maxLagS: 2.0))
        XCTAssertLessThan(p.value, 0)
        XCTAssertTrue((1.0...2.0).contains(p.lagS))
    }
}
