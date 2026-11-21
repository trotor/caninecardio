import AVFoundation
import CardioCore
import Storage
import XCTest
@testable import Acquisition

/// Test double: emits 100 Hz samples stamped with the real uptime clock. Never used by the app.
@MainActor
final class FakeMotionSource: MotionSource {
    var isAccelerometerAvailable = true
    var isGyroscopeAvailable = true
    /// Added to every timestamp, to simulate sensor timestamps on a different clock.
    var timestampOffset = 0.0
    private var task: Task<Void, Never>?
    private(set) var startCount = 0

    func start(requestedRateHz: Double, capture: MotionCapture) throws {
        guard isAccelerometerAvailable else { throw AcquisitionError.accelerometerUnavailable }
        startCount += 1
        let gyro = isGyroscopeAvailable
        let offset = timestampOffset
        // Emits every sample due on a nominal 100 Hz grid, catching up after scheduler delays, so
        // the sample count does not depend on how promptly the test machine wakes the task.
        task = Task.detached {
            let t0 = ProcessInfo.processInfo.systemUptime
            var k = 0
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                while t0 + Double(k) * 0.01 <= now {
                    let t = t0 + Double(k) * 0.01 + offset
                    capture.append(.accelerometer, Vector3Sample(t: t, x: 0, y: 0, z: -1, receivedAt: now + offset))
                    if gyro { capture.append(.gyroscope, Vector3Sample(t: t, x: 0.01, y: 0, z: 0, receivedAt: now + offset)) }
                    k += 1
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Test double: drives a real `AudioTapProcessor` with synthetic 100 ms buffers at 8 kHz whose
/// host times follow the uptime clock, so gating, WAV writing and metadata assembly are exercised.
@MainActor
final class FakeAudioSource: AudioSource {
    var onInterruption: (@MainActor (String) -> Void)?
    private var processor: AudioTapProcessor?
    private var task: Task<Void, Never>?
    nonisolated static let rate = 8000.0

    func start(live: LiveRingBuffer, gate: CaptureGate) throws -> AudioInputInfo {
        let proc = AudioTapProcessor(sampleRate: Self.rate, channelCount: 1, live: live, gate: gate,
                                     hostTimeToSeconds: { Double($0) / 1e9 })
        processor = proc
        task = Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
            let t0 = ProcessInfo.processInfo.systemUptime
            var k = 0
            while !Task.isCancelled {
                let start = t0 + Double(k) * 0.1
                while ProcessInfo.processInfo.systemUptime < start + 0.1 { try? await Task.sleep(for: .milliseconds(5)) }
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
                buf.frameLength = 800
                for i in 0..<800 { buf.floatChannelData![0][i] = Float(sin(Double(k * 800 + i) * 0.05)) * 0.1 }
                let time = AVAudioTime(hostTime: UInt64((start * 1e9).rounded()), sampleTime: AVAudioFramePosition(k * 800), atRate: Self.rate)
                proc.process(buf, time: time, receivedAt: ProcessInfo.processInfo.systemUptime)
                k += 1
            }
        }
        return AudioInputInfo(sampleRate: Self.rate, channelCount: 1, inputLatencyS: 0.005, ioBufferDurationS: 0.01, sessionMode: "fake")
    }

    func openFile(url: URL) throws { try processor?.openFile(url: url) }
    func closeFile() -> AudioTapProcessor.FileSummary? { processor?.closeFile() }
    var framesWritten: Int64 { processor?.framesWritten ?? 0 }

    func stop() {
        task?.cancel()
        task = nil
        _ = processor?.closeFile()
        processor = nil
    }
}

@MainActor
final class MeasurementSessionTests: XCTestCase {
    var root: URL!
    var store: SessionStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MS-\(UUID().uuidString)")
        store = SessionStore(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ motion: FakeMotionSource = FakeMotionSource(), audio: AudioSource? = nil) -> MeasurementSession {
        let s = MeasurementSession(motion: motion, audio: audio, store: store,
                                   deviceInfo: DeviceInfo(modelIdentifier: "test", systemName: "test", systemVersion: "0"),
                                   appVersion: "test")
        s.configuration.recordAudio = audio != nil
        s.configuration.startDelayS = 0
        s.configuration.durationS = 0.5
        return s
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testTimedRecordingIsSavedWithSamplesInsideWindow() async throws {
        let session = makeSession()
        session.record()
        XCTAssertEqual(session.phase, .recording)
        await waitUntil { session.lastSaved != nil }
        XCTAssertEqual(session.phase, .idle)
        let meta = try XCTUnwrap(session.lastSaved)
        XCTAssertEqual(meta.endReason, .completed)
        XCTAssertFalse(meta.isSynthetic)
        XCTAssertEqual(meta.recordedDurationS, 0.5, accuracy: 1e-9)

        let loaded = try store.load(id: meta.id)
        let accel = try XCTUnwrap(loaded.accelerometer)
        XCTAssertGreaterThan(accel.samples.count, 20)
        for s in accel.samples {
            XCTAssertGreaterThanOrEqual(s.t, meta.referenceUptimeS)
            XCTAssertLessThanOrEqual(s.t, meta.referenceUptimeS + 0.5)
        }
        XCTAssertNotNil(loaded.gyroscope)
        XCTAssertTrue(meta.notes.contains { $0.contains("Audio recording was turned off") })
    }

    func testAudioIsTrimmedToWindowAndDescribedInMetadata() async throws {
        let session = makeSession(audio: FakeAudioSource())
        session.configuration.startDelayS = 0.3
        session.record()
        XCTAssertEqual(session.phase, .countdown)
        await waitUntil { session.lastSaved != nil }
        let meta = try XCTUnwrap(session.lastSaved)
        let audio = try XCTUnwrap(meta.audio)
        XCTAssertEqual(audio.sampleRateHz, FakeAudioSource.rate)
        XCTAssertEqual(audio.frameCount, 4000, "0.5 s at 8 kHz, cut exactly to the window")
        XCTAssertEqual(audio.firstFrameUptimeS!, meta.referenceUptimeS, accuracy: 1 / FakeAudioSource.rate)
        XCTAssertEqual(audio.sampleTimeDiscontinuities, 0)
        XCTAssertEqual(audio.inputLatencyS, 0.005)
        let loaded = try store.load(id: meta.id)
        let wav = try AVAudioFile(forReading: try XCTUnwrap(loaded.audioURL))
        XCTAssertEqual(wav.length, 4000)
        XCTAssertTrue(loaded.exportURLs.map(\.lastPathComponent).contains("audio.wav"))
    }

    func testCancelDuringCountdownWithAudioLeavesNoFiles() async throws {
        let session = makeSession(audio: FakeAudioSource())
        session.configuration.startDelayS = 5
        session.record()
        try await Task.sleep(for: .milliseconds(250))
        session.stop()
        XCTAssertEqual(session.phase, .idle)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testTimestampClockMismatchFailsLoudly() async throws {
        let motion = FakeMotionSource()
        motion.timestampOffset = 1000
        let session = makeSession(motion)
        session.record()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(session.liveStatus().sensorError?.contains("uptime clock") ?? false)
        await waitUntil { session.lastSaved != nil }
        guard case .failed(let message) = session.phase else { return XCTFail("expected failure, got \(session.phase)") }
        XCTAssertTrue(message.contains("uptime clock"))
        XCTAssertEqual(session.lastSaved?.endReason, .failed)
        XCTAssertEqual(session.lastSaved?.accelerometer?.sampling.sampleCount, 0)
    }

    func testStopDuringRecordingSavesShorterSession() async throws {
        let session = makeSession()
        session.configuration.durationS = 30
        session.record()
        try await Task.sleep(for: .milliseconds(300))
        session.stop()
        await waitUntil { session.lastSaved != nil }
        let meta = try XCTUnwrap(session.lastSaved)
        XCTAssertEqual(meta.endReason, .stoppedByUser)
        XCTAssertLessThan(meta.recordedDurationS, 2)
    }

    func testCancelDuringCountdownDiscardsFolder() async throws {
        let session = makeSession()
        session.configuration.startDelayS = 5
        session.record()
        XCTAssertEqual(session.phase, .countdown)
        XCTAssertNotNil(session.liveStatus().countdownRemainingS)
        session.stop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.lastSaved)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInterruptionEndsRecordingAndIsRecorded() async throws {
        let session = makeSession()
        session.configuration.durationS = 30
        session.record()
        try await Task.sleep(for: .milliseconds(200))
        session.interrupt("Test interruption")
        await waitUntil { session.lastSaved != nil }
        XCTAssertEqual(session.lastSaved?.endReason, .interrupted)
        XCTAssertTrue(session.lastSaved?.notes.contains("Test interruption") ?? false)
    }

    func testMissingAccelerometerFailsWithInformativeMessage() {
        let motion = FakeMotionSource()
        motion.isAccelerometerAvailable = false
        let session = makeSession(motion)
        session.record()
        guard case .failed(let message) = session.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Simulator"))
        XCTAssertTrue((try? store.list())?.isEmpty ?? true)
    }

    func testPreviewDoesNotRecordAndReportsRates() async throws {
        let session = makeSession()
        session.startPreview()
        XCTAssertEqual(session.phase, .previewing)
        try await Task.sleep(for: .milliseconds(600))
        let status = session.liveStatus()
        XCTAssertNotNil(status.accelerometerRateHz)
        XCTAssertEqual(status.recordedAccelerometer, 0)
        XCTAssertEqual(status.motionLevel, .still)
        session.stopPreview()
        XCTAssertEqual(session.phase, .idle)
    }
}
