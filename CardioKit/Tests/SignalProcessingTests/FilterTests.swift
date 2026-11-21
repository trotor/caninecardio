import XCTest
@testable import SignalProcessing

/// Magnitude responses are cross-checked against scipy.signal (1.17) reference values computed
/// with `butter(..., fs=100, output='sos')` + `sosfreqz`. See analysis/reference_values.py.
final class FilterTests: XCTestCase {
    let fs = 100.0
    let freqs = [0.05, 0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 40.0]

    private func assertMatches(_ f: SOSFilter, _ ref: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for (freq, expected) in zip(freqs, ref) {
            let got = f.magnitude(at: freq, fs: fs)
            XCTAssertEqual(got, expected, accuracy: max(1e-9, expected * 1e-6), "at \(freq) Hz", file: file, line: line)
        }
    }

    func testLowpassOrder4MatchesScipy() throws {
        assertMatches(try Butterworth.lowpass(order: 4, cutoffHz: 10, sampleRateHz: fs),
                      [1.0, 1.0, 1.0, 0.9999999962, 0.9999990120, 0.9984098980, 0.7071067812, 0.0399680383, 0.0031056050, 0.0001242248])
    }

    func testHighpassOrder4MatchesScipy() throws {
        assertMatches(try Butterworth.highpass(order: 4, cutoffHz: 5, sampleRateHz: fs),
                      [0.0000000097, 0.0000001548, 0.0000967770, 0.0015499602, 0.0248898909, 0.7071067812, 0.9984098980, 0.9999974498, 0.9999999846, 1.0])
    }

    func testOddOrdersMatchScipy() throws {
        assertMatches(try Butterworth.lowpass(order: 3, cutoffHz: 2, sampleRateHz: fs),
                      [0.9999999999, 0.9999999922, 0.9998788528, 0.9923229983, 0.7071067812, 0.0625556814, 0.0072596578, 0.0006493405, 0.0000955078, 0.0000085425])
        assertMatches(try Butterworth.highpass(order: 3, cutoffHz: 0.5, sampleRateHz: fs),
                      [0.0009997552, 0.0079978493, 0.7071067812, 0.9922891719, 0.9998788528, 0.9999995240, 0.9999999936, 0.9999999999, 1.0, 1.0])
    }

    func testBandpassPresetsMatchScipy() throws {
        assertMatches(try FrequencyBand.cardiacVibration.filter(order: 2, sampleRateHz: fs),
                      [0.0000983593, 0.0003934391, 0.0098370562, 0.0393390772, 0.1558610482, 0.7070447954, 0.9714042621, 0.9622173633, 0.7070447954, 0.1961154474])
        assertMatches(try FrequencyBand.respiration.filter(order: 2, sampleRateHz: fs),
                      [0.2425337417, 0.7070714745, 0.9693956952, 0.7070714745, 0.2420841354, 0.0393390795, 0.0093543687, 0.0018709523, 0.0005213238, 0.0001042648])
    }

    func testFiltfiltMatchesScipyInterior() throws {
        let x = (0..<2000).map { i -> Double in
            let t = Double(i) / fs
            return sin(2 * .pi * 1.3 * t) + 0.5 * sin(2 * .pi * 12 * t) + 0.2 * cos(2 * .pi * 0.2 * t) + 0.01 * t
        }
        let y = try FrequencyBand.cardiacVibration.filter(order: 2, sampleRateHz: fs).filtfilt(x, padLength: 60)
        let expected: [Int: Double] = [500: 0.0000004954, 777: 0.4858594040, 1000: 0.0000004954,
                                       1234: 0.2344153222, 1500: 0.0000004954]
        for (i, v) in expected { XCTAssertEqual(y[i], v, accuracy: 1e-6, "index \(i)") }
    }

    func testFiltfiltIsZeroPhase() throws {
        // A Gaussian pulse must stay centred after zero-phase band-pass filtering.
        let n = 1000, centre = 500
        let x = (0..<n).map { i -> Double in
            let d = Double(i - centre) / fs
            return exp(-0.5 * pow(d / 0.03, 2)) * cos(2 * .pi * 12 * d)
        }
        let y = try Butterworth.bandpass(order: 4, lowHz: 5, highHz: 25, sampleRateHz: fs).filtfilt(x)
        let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) }!
        XCTAssertEqual(peak, centre)
    }

    func testCausalFilterDelaysButFiltfiltDoesNot() throws {
        let f = try Butterworth.lowpass(order: 4, cutoffHz: 5, sampleRateHz: fs)
        let x = (0..<400).map { i in exp(-0.5 * pow(Double(i - 200) / 10, 2)) }
        let causal = f.filter(x), zero = f.filtfilt(x)
        XCTAssertGreaterThan(causal.indices.max { causal[$0] < causal[$1] }!, 202)
        XCTAssertEqual(zero.indices.max { zero[$0] < zero[$1] }!, 200)
    }

    func testSteadyStateInitHasNoStartTransientForConstantInput() throws {
        let f = try Butterworth.lowpass(order: 4, cutoffHz: 2, sampleRateHz: fs)
        let y = f.filter([Double](repeating: -0.98, count: 300))
        for v in y { XCTAssertEqual(v, -0.98, accuracy: 1e-9) }
    }

    func testDesignRejectsInvalidParameters() {
        XCTAssertThrowsError(try Butterworth.lowpass(order: 0, cutoffHz: 5, sampleRateHz: fs))
        XCTAssertThrowsError(try Butterworth.lowpass(order: 2, cutoffHz: 50, sampleRateHz: fs))
        XCTAssertThrowsError(try Butterworth.bandpass(order: 2, lowHz: 10, highHz: 5, sampleRateHz: fs))
    }
}
