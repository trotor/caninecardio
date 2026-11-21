import CardioCore
import SyntheticData
import XCTest
@testable import SignalProcessing

final class BeatEditsTests: XCTestCase {
    func testApplyRemovesAndAdds() {
        let edits = BeatEdits(removed: [2.0], added: [2.5])
        XCTAssertEqual(edits.apply(to: [1.0, 2.0, 3.0]), [1.0, 2.5, 3.0])
    }

    func testToggleCycle() {
        let detected = [1.0, 2.0, 3.0]
        var e = BeatEdits()
        e.toggle(near: 2.05, detected: detected, addAt: nil)          // reject detected beat 2.0
        XCTAssertEqual(e.removed, [2.0])
        e.toggle(near: 1.98, detected: detected, addAt: nil)          // un-reject it
        XCTAssertTrue(e.isEmpty)
        e.toggle(near: 2.5, detected: detected, addAt: 2.47)          // add a beat at the envelope peak
        XCTAssertEqual(e.added, [2.47])
        e.toggle(near: 2.5, detected: detected, addAt: 2.47)          // delete the added beat
        XCTAssertTrue(e.isEmpty)
        e.toggle(near: 2.5, detected: detected, addAt: nil)           // nothing near, nothing to add
        XCTAssertTrue(e.isEmpty)
    }

    func testEvaluateReproducesPipelineAndReflectsEdits() throws {
        var c = SyntheticConfig(); c.durationS = 30
        let rec = SyntheticGenerator.generate(c)
        let result = try CandidateBeatPipeline().run(rec.accelerometer)
        let (intervals, summary) = result.evaluate(beatTimes: result.beatTimes, config: .init())
        XCTAssertEqual(intervals, result.intervals)
        XCTAssertEqual(summary, result.summary)

        // Rejecting one beat produces a long, flagged interval.
        var edits = BeatEdits()
        edits.toggle(near: result.beatTimes[10], detected: result.beatTimes, addAt: nil)
        let (edited, _) = result.evaluate(beatTimes: edits.apply(to: result.beatTimes), config: .init())
        XCTAssertEqual(edited.count, intervals.count - 1)
        XCTAssertTrue(edited.contains { $0.flags.contains(.abruptChange) })
    }

    func testNearestEnvelopePeakSnapsToBeat() throws {
        var c = SyntheticConfig(); c.durationS = 20
        let rec = SyntheticGenerator.generate(c)
        let result = try CandidateBeatPipeline().run(rec.accelerometer)
        let beat = result.beatTimes[5]
        XCTAssertEqual(try XCTUnwrap(result.nearestEnvelopePeak(to: beat + 0.08)), beat, accuracy: 0.011)
    }

    func testChooseAxisPrefersReliable() throws {
        let rec = SyntheticScenario.regular.generate()
        let good = try CandidateBeatPipeline().run(rec.accelerometer)
        var noisy = SyntheticScenario.lowSNR.config; noisy.seed = 3
        let bad = try CandidateBeatPipeline().run(SyntheticGenerator.generate(noisy).accelerometer)
        XCTAssertTrue(good.summary.isReliable)
        XCTAssertFalse(bad.summary.isReliable)
        XCTAssertEqual(CandidateBeatPipeline.chooseAxis([.x: bad, .z: good]), .z)
    }
}
