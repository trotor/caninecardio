import XCTest
@testable import CardioCore

final class SamplingStatisticsTests: XCTestCase {
    func testRegularStream() {
        let t = (0..<1001).map { 10 + Double($0) * 0.01 }
        let s = SamplingStatistics.compute(timestamps: t)
        XCTAssertEqual(s.sampleCount, 1001)
        XCTAssertEqual(s.effectiveRateHz!, 100, accuracy: 1e-6)
        XCTAssertEqual(s.spanS, 10, accuracy: 1e-9)
        XCTAssertEqual(s.gapCount, 0)
        XCTAssertEqual(s.estimatedMissingSamples, 0)
        XCTAssertEqual(s.stdIntervalS!, 0, accuracy: 1e-9)
    }

    func testDetectsGapsAndEstimatesMissingSamples() {
        var t = (0..<200).map { Double($0) * 0.01 }
        t.removeSubrange(50..<53)    // 3 missing -> one 40 ms interval
        t.remove(at: 120)            // 1 missing -> one 20 ms interval
        let s = SamplingStatistics.compute(timestamps: t)
        XCTAssertEqual(s.gapCount, 2)
        XCTAssertEqual(s.estimatedMissingSamples, 4)
        XCTAssertEqual(s.maxIntervalS!, 0.04, accuracy: 1e-9)
    }

    func testCountsNonIncreasingTimestamps() {
        let s = SamplingStatistics.compute(timestamps: [0, 0.01, 0.01, 0.005, 0.02])
        XCTAssertEqual(s.nonIncreasingIntervals, 2)
    }

    func testDegenerateInputs() {
        XCTAssertNil(SamplingStatistics.compute(timestamps: []).effectiveRateHz)
        XCTAssertEqual(SamplingStatistics.compute(timestamps: [1]).sampleCount, 1)
    }
}

final class LiveRingBufferTests: XCTestCase {
    func testWrapsAndKeepsNewest() {
        let b = LiveRingBuffer(capacity: 4, channelCount: 3)
        for i in 0..<6 { b.append(t: Double(i), Double(i), Double(10 * i), Double(100 * i)) }
        let s = b.snapshot()
        XCTAssertEqual(s.times, [2, 3, 4, 5])
        XCTAssertEqual(s.channels[1], [20, 30, 40, 50])
        XCTAssertEqual(s.channels[2], [200, 300, 400, 500])
        XCTAssertEqual(b.totalAppended, 6)
    }

    func testSnapshotSince() {
        let b = LiveRingBuffer(capacity: 10, channelCount: 1)
        for i in 0..<10 { b.append(t: Double(i), Double(i)) }
        XCTAssertEqual(b.snapshot(since: 7).times, [7, 8, 9])
    }

    func testConcurrentAppendsAreSafe() {
        let b = LiveRingBuffer(capacity: 1000, channelCount: 1)
        DispatchQueue.concurrentPerform(iterations: 8) { k in
            for i in 0..<1000 { b.append(t: Double(k * 1000 + i), 1) }
        }
        XCTAssertEqual(b.totalAppended, 8000)
        XCTAssertEqual(b.snapshot().times.count, 1000)
    }

    func testDecimationPreservesExtremes() {
        let times = (0..<1000).map(Double.init)
        var values = [Double](repeating: 0, count: 1000)
        values[333] = 5; values[777] = -4
        let d = LiveSnapshot(times: times, channels: [values]).decimated(buckets: 50)
        XCTAssertLessThanOrEqual(d.times.count, 100)
        XCTAssertEqual(d.channels[0].max(), 5)
        XCTAssertEqual(d.channels[0].min(), -4)
    }
}

final class MotionLevelTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(MotionLevel.classify(magnitudeStdG: nil), .unknown)
        XCTAssertEqual(MotionLevel.classify(magnitudeStdG: 0.001), .still)
        XCTAssertEqual(MotionLevel.classify(magnitudeStdG: 0.01), .slight)
        XCTAssertEqual(MotionLevel.classify(magnitudeStdG: 0.1), .moving)
    }
}
