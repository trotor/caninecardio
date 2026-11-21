import CardioCore
import Foundation
import Observation
import Storage

/// Orchestrates one measurement: live preview, optional start delay, timed recording, saving.
///
/// Sensors start when the preview or recording starts. Samples are kept only while the shared
/// `CaptureGate` is open, so the recording covers exactly `[start, start + duration]` on the
/// uptime clock for both motion and audio (audio is trimmed to the frame).
@MainActor
@Observable
public final class MeasurementSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case previewing
        case countdown
        case recording
        case saving
        case failed(String)

        public var sensorsActive: Bool {
            switch self {
            case .previewing, .countdown, .recording: true
            default: false
            }
        }
    }

    public struct Configuration: Equatable, Sendable {
        public static let durationOptions: [Double] = [30, 60, 120]
        public static let startDelayOptions: [Double] = [0, 5, 10]

        public var durationS: Double = 60
        public var startDelayS: Double = 5
        public var recordAudio = true
        public var requestedMotionRateHz: Double = 100
        public var label = ""

        public init() {}
    }

    public struct LiveStatus: Equatable, Sendable {
        public var countdownRemainingS: Double?
        public var elapsedS: Double?
        public var remainingS: Double?
        public var accelerometerRateHz: Double?
        public var gyroscopeRateHz: Double?
        public var audioSampleRateHz: Double?
        public var recordedAccelerometer = 0
        public var recordedGyroscope = 0
        public var audioFramesWritten: Int64 = 0
        public var motionLevel: MotionLevel = .unknown
        public var sensorError: String?
    }

    public var configuration = Configuration()
    public private(set) var phase: Phase = .idle
    public private(set) var lastSaved: SessionMetadata?
    public private(set) var audioInput: AudioInputInfo?
    public private(set) var recordingWindow: ClosedRange<Double>?

    @ObservationIgnored public let gate = CaptureGate()
    @ObservationIgnored public let capture: MotionCapture
    /// Audio envelope at 100 Hz: channel 0 = RMS, channel 1 = peak (full scale = 1).
    @ObservationIgnored public let audioLive = LiveRingBuffer(capacity: 1500, channelCount: 2)

    @ObservationIgnored private let motion: MotionSource
    @ObservationIgnored private let audio: AudioSource?
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let deviceInfo: DeviceInfo
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let now: @Sendable () -> Double
    @ObservationIgnored private var audioRunning = false
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var createdAt: Date?
    @ObservationIgnored private var notes: [String] = []
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// Time allowed after the window closes for late-delivered samples to arrive.
    public static let lateDeliveryMarginS = 0.3

    public init(motion: MotionSource, audio: AudioSource?, store: SessionStore, deviceInfo: DeviceInfo,
                appVersion: String, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.motion = motion
        self.audio = audio
        self.store = store
        self.deviceInfo = deviceInfo
        self.appVersion = appVersion
        self.now = now
        capture = MotionCapture(gate: gate, expectedSamplesPerSensor: 26_000)
        self.audio?.onInterruption = { [weak self] message in self?.interrupt(message) }
    }

    public var isMotionAvailable: Bool { motion.isAccelerometerAvailable }

    // MARK: - Commands

    public func startPreview() {
        guard phase == .idle || isFailed else { return }
        do {
            try startSensors()
            phase = .previewing
        } catch {
            fail(error)
        }
    }

    public func stopPreview() {
        guard phase == .previewing else { return }
        stopSensors()
        phase = .idle
    }

    public func record() {
        guard phase == .idle || phase == .previewing || isFailed else { return }
        do {
            if !phase.sensorsActive { try startSensors() }
            notes = []
            if !motion.isGyroscopeAvailable { notes.append("Gyroscope not available on this device.") }
            if !configuration.recordAudio { notes.append("Audio recording was turned off by the operator.") }
            let id = SessionStore.makeSessionID()
            let dir = try store.createSessionDirectory(id: id)
            sessionID = id
            if audioRunning, let audio {
                try audio.openFile(url: dir.appendingPathComponent("audio.wav"))
            }
            let start = now() + configuration.startDelayS
            let end = start + configuration.durationS
            gate.open(start: start, end: end)
            recordingWindow = start...end
            createdAt = Date().addingTimeInterval(configuration.startDelayS)
            phase = configuration.startDelayS > 0 ? .countdown : .recording
            scheduleTimers(start: start, end: end)
        } catch {
            discardPending()
            stopSensors()
            fail(error)
        }
    }

    /// Stop button: cancels a countdown, ends a recording early (saving it), or ends preview.
    public func stop() {
        switch phase {
        case .previewing:
            stopPreview()
        case .countdown:
            timerTask?.cancel()
            discardPending()
            stopSensors()
            phase = .idle
        case .recording:
            timerTask?.cancel()
            gate.close(at: now())
            Task { await finish(.stoppedByUser) }
        default:
            break
        }
    }

    /// System interruption (audio session interrupted, app backgrounded).
    public func interrupt(_ message: String) {
        switch phase {
        case .recording:
            timerTask?.cancel()
            gate.close(at: now())
            notes.append(message)
            Task { await finish(.interrupted) }
        case .countdown:
            timerTask?.cancel()
            discardPending()
            stopSensors()
            phase = .failed(message)
        case .previewing:
            stopSensors()
            phase = .idle
        default:
            break
        }
    }

    public func dismissError() {
        if isFailed { phase = .idle }
    }

    // MARK: - Status (polled by the UI at display rate, never pushed from callbacks)

    public func liveStatus() -> LiveStatus {
        var s = LiveStatus()
        let t = now()
        if let w = recordingWindow, phase == .countdown || phase == .recording || phase == .saving {
            if t < w.lowerBound {
                s.countdownRemainingS = w.lowerBound - t
            } else {
                s.elapsedS = min(t, w.upperBound) - w.lowerBound
                s.remainingS = max(0, w.upperBound - t)
            }
        }
        let accel = capture.accelerometerLive.snapshot(since: t - 2.5)
        let gyro = capture.gyroscopeLive.snapshot(since: t - 2.5)
        s.accelerometerRateHz = SamplingStatistics.compute(timestamps: accel.times).effectiveRateHz
        s.gyroscopeRateHz = SamplingStatistics.compute(timestamps: gyro.times).effectiveRateHz
        s.audioSampleRateHz = audioRunning ? audioInput?.sampleRate : nil
        let counts = capture.counts
        s.recordedAccelerometer = counts.recordedAccelerometer
        s.recordedGyroscope = counts.recordedGyroscope
        s.sensorError = counts.lastError
        if let offset = clockOffset(at: t) {
            s.sensorError = Self.clockMismatchMessage(offset)
        }
        s.audioFramesWritten = audio?.framesWritten ?? 0
        let lastSecond = accel.times.lastIndex { $0 < t - 1 }.map { $0 + 1 } ?? 0
        if accel.times.count - lastSecond >= 20 {
            let mags = (lastSecond..<accel.times.count).map { i in
                (accel.channels[0][i] * accel.channels[0][i] + accel.channels[1][i] * accel.channels[1][i]
                    + accel.channels[2][i] * accel.channels[2][i]).squareRoot()
            }
            s.motionLevel = MotionLevel.classify(magnitudeStdG: Statistics.std(mags))
        }
        return s
    }

    // MARK: - Internals

    /// Sensor timestamps are compared with `ProcessInfo.systemUptime` to apply the capture gate.
    /// If the newest sample is more than a second away from "now", that assumption has failed and
    /// the gate would silently discard everything.
    private func clockOffset(at t: Double) -> Double? {
        guard let last = capture.accelerometerLive.latestTime else { return nil }
        let offset = t - last
        return abs(offset) > 1.0 ? offset : nil
    }

    static func clockMismatchMessage(_ offset: Double) -> String {
        String(format: "Sensor timestamps differ from the device uptime clock by %.1f s, so the recording window cannot be applied. Please report this with your device model and iOS version.", offset)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ error: Error) {
        phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func startSensors() throws {
        capture.resetCounts()
        audioLive.reset()
        try motion.start(requestedRateHz: configuration.requestedMotionRateHz, capture: capture)
        if configuration.recordAudio, let audio {
            do {
                audioInput = try audio.start(live: audioLive, gate: gate)
                audioRunning = true
            } catch {
                motion.stop()
                throw error
            }
        } else {
            audioInput = nil
        }
    }

    private func stopSensors() {
        motion.stop()
        if audioRunning { audio?.stop() }
        audioRunning = false
    }

    private func scheduleTimers(start: Double, end: Double) {
        timerTask?.cancel()
        let now = self.now
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, start - now())))
            guard !Task.isCancelled else { return }
            if self?.phase == .countdown { self?.phase = .recording }
            try? await Task.sleep(for: .seconds(max(0, end - now())))
            guard !Task.isCancelled else { return }
            await self?.finish(.completed)
        }
    }

    /// Removes the folder of a recording that never started (countdown cancelled, start failed).
    private func discardPending() {
        _ = audio?.closeFile()
        gate.clear()
        recordingWindow = nil
        if let id = sessionID { try? store.delete(id: id) }
        sessionID = nil
    }

    private func finish(_ reason: SessionMetadata.EndReason) async {
        guard phase == .recording, let id = sessionID else { return }
        phase = .saving
        // Core Motion and the audio tap deliver with some latency: wait for in-window samples.
        try? await Task.sleep(for: .seconds(Self.lateDeliveryMarginS))
        let window = gate.current
        let clockOffset = clockOffset(at: now())
        gate.clear()
        let audioSummary = audio?.closeFile()
        let input = audioInput
        stopSensors()
        let (accel, gyro) = capture.takeRecorded()
        sessionID = nil

        var notes = self.notes
        var reason = reason
        var failure: String?
        let received = capture.counts.receivedAccelerometer
        if let err = capture.counts.lastError { notes.append("Motion sensor error: \(err)") }
        if accel.isEmpty && received > 0 {
            failure = clockOffset.map(Self.clockMismatchMessage)
                ?? "No accelerometer samples fell inside the recording window although \(received) were received."
            notes.append(failure!)
            reason = .failed
        }
        if let err = audioSummary?.writeError { notes.append("Audio write error: \(err)") }
        let reference = window?.lowerBound ?? recordingWindow?.lowerBound ?? 0
        let accelSeries = MotionSeries(kind: .accelerometer, samples: accel)
        let gyroSeries = MotionSeries(kind: .gyroscope, samples: gyro)
        let audioInfo = audioSummary.flatMap { sum -> AudioStreamInfo? in
            guard let input else { return nil }
            return AudioStreamInfo(
                fileName: sum.fileName, fileFormat: AudioTapProcessor.fileFormatDescription,
                sampleRateHz: input.sampleRate, channelCount: input.channelCount, frameCount: sum.framesWritten,
                firstFrameUptimeS: sum.firstFrameUptime, firstFrameSampleTime: sum.firstFrameSampleTime,
                sampleClockDriftPPM: sum.driftPPM, sampleTimeDiscontinuities: sum.discontinuities,
                discontinuityFrames: sum.discontinuityFrames, inputLatencyS: input.inputLatencyS,
                ioBufferDurationS: input.ioBufferDurationS, sessionMode: input.sessionMode,
                inputPortName: input.portName, inputDataSource: input.dataSource,
                medianBufferDeliveryLatencyS: sum.medianDeliveryLatency)
        }
        let metadata = SessionMetadata(
            id: id, isSynthetic: false, createdAt: createdAt ?? Date(), label: configuration.label,
            requestedDurationS: configuration.durationS,
            recordedDurationS: window.map { $0.upperBound - $0.lowerBound } ?? 0,
            endReason: reason, referenceUptimeS: reference,
            requestedMotionRateHz: configuration.requestedMotionRateHz,
            accelerometer: .summarize(accelSeries),
            gyroscope: gyro.isEmpty && !motion.isGyroscopeAvailable ? nil : .summarize(gyroSeries),
            audio: audioInfo, device: deviceInfo, appVersion: appVersion, notes: notes)

        let store = self.store
        let gyroToSave = metadata.gyroscope == nil ? nil : gyroSeries
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.finalize(metadata: metadata, accelerometer: accelSeries, gyroscope: gyroToSave)
            }.value
            lastSaved = metadata
            recordingWindow = nil
            phase = failure.map { .failed($0) } ?? .idle
        } catch {
            recordingWindow = nil
            phase = .failed(AcquisitionError.storageFailed(error.localizedDescription).errorDescription ?? "")
        }
    }
}
