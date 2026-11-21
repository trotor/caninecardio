import CardioCore
import Foundation
import SignalProcessing
import SyntheticData

/// Runs the candidate pipeline on a synthetic scenario and scores it against ground truth.
struct ScenarioOutcome {
    var scenario: String
    var result: CandidateBeatPipeline.Result
    var match: BeatMatchResult
    var truth: SyntheticRecording

    var line: String {
        String(format: "%-28@ beats %3d det %3d  sens %.3f  ppv %.3f  timing %+5.1f±%4.1f ms  |IBI err| med %5.1f ms  accepted %3d/%3d  period %.2f  excl %.2f  reliable %@  HR %@",
               scenario as NSString, truth.beatTimes.count, result.peaks.count, match.sensitivity,
               match.positivePredictiveValue, match.meanTimingErrorS * 1000, match.timingErrorSDS * 1000,
               match.medianAbsIntervalErrorMs, result.summary.acceptedCount, result.summary.intervalCount,
               result.periodicity ?? .nan, result.excludedFraction,
               result.summary.isReliable ? "yes" : "no " as NSString,
               (result.summary.meanRateBPM.map { String(format: "%.1f", $0) } ?? "–") as NSString)
    }
}

func evaluate(_ rec: SyntheticRecording, config: CandidateBeatPipeline.Config = .init(), toleranceS: Double = 0.1) throws -> ScenarioOutcome {
    let result = try CandidateBeatPipeline(config: config).run(rec.accelerometer)
    // Skip the first/last second (filter edges) when scoring.
    let first = rec.accelerometer.samples.first!.t + 1, last = rec.accelerometer.samples.last!.t - 1
    let match = BeatMatcher.match(detected: result.beatTimes, reference: rec.beatTimes, toleranceS: toleranceS,
                                  within: first...last)
    return ScenarioOutcome(scenario: rec.name, result: result, match: match, truth: rec)
}
