#if DEBUG
import Acquisition
import CardioCore
import Foundation

/// DEBUG-only smoke test of the real microphone path (AVAudioEngine tap, gating, WAV writing).
/// The Simulator has no motion sensors, so this is the only way to exercise the audio tap's
/// threading there. Launch with `-CCAudioSelfTest`; results are printed to the console.
enum DebugSelfTest {
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-CCAudioSelfTest") else { return }
        Task { @MainActor in
            let mic = MicrophoneSource()
            let gate = CaptureGate()
            let live = LiveRingBuffer(capacity: 500, channelCount: 2)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.wav")
            do {
                let info = try mic.start(live: live, gate: gate)
                NSLog("%@", "[selftest] input \(info.sampleRate) Hz, \(info.channelCount) ch, latency \(info.inputLatencyS ?? -1), mode \(info.sessionMode)")
                try mic.openFile(url: url)
                let now = ProcessInfo.processInfo.systemUptime
                gate.open(start: now + 0.2, end: now + 1.2)
                try await Task.sleep(for: .seconds(2))
                let summary = mic.closeFile()
                mic.stop()
                let expected = Int(info.sampleRate.rounded())
                NSLog("%@", "[selftest] frames written \(summary?.framesWritten ?? -1) (expected \(expected)), envelope points \(live.totalAppended), discontinuities \(summary?.discontinuities ?? -1), drift ppm \(summary?.driftPPM.map { String($0) } ?? "nil"), error \(summary?.writeError ?? "none")")
                NSLog("%@", "[selftest] PASS=\(summary?.framesWritten == Int64(expected) && summary?.writeError == nil)")
            } catch {
                NSLog("%@", "[selftest] FAILED: \(error.localizedDescription)")
            }
        }
    }
}
#endif
