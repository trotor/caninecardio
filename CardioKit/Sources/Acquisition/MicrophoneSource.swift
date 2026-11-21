#if os(iOS)
@preconcurrency import AVFoundation
import CardioCore
import Foundation

/// Microphone permission helpers.
public enum MicrophonePermission {
    public enum Status: Sendable { case undetermined, denied, granted }

    public static var status: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    public static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Built-in microphone via `AVAudioEngine`, recorded without voice processing.
///
/// The audio session uses mode `.measurement`, which disables automatic gain control and other
/// signal processing where the hardware allows. The hardware sample rate is used as-is.
@MainActor
public final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var processor: AudioTapProcessor?
    private var observers: [any NSObjectProtocol] = []
    public var onInterruption: (@MainActor (String) -> Void)?

    public init() {}

    public func start(live: LiveRingBuffer, gate: CaptureGate) throws -> AudioInputInfo {
        guard MicrophonePermission.status == .granted else { throw AcquisitionError.microphonePermissionDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            throw AcquisitionError.audioSessionFailed(error.localizedDescription)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AcquisitionError.microphoneUnavailable("input format reports \(format.sampleRate) Hz, \(format.channelCount) channels")
        }
        let proc = AudioTapProcessor(sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                                     live: live, gate: gate)
        processor = proc
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(proc))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AcquisitionError.microphoneUnavailable(error.localizedDescription)
        }
        observeInterruptions()
        let route = session.currentRoute.inputs.first
        return AudioInputInfo(sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                              inputLatencyS: session.inputLatency, ioBufferDurationS: session.ioBufferDuration,
                              sessionMode: session.mode.rawValue, portName: route?.portName,
                              dataSource: route?.selectedDataSource?.dataSourceName)
    }

    public func openFile(url: URL) throws {
        guard let processor else { throw AcquisitionError.microphoneUnavailable("audio input not started") }
        try processor.openFile(url: url)
    }

    public func closeFile() -> AudioTapProcessor.FileSummary? {
        processor?.closeFile()
    }

    public var framesWritten: Int64 { processor?.framesWritten ?? 0 }

    public func stop() {
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = processor?.closeFile()
        processor = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Built outside the main actor: AVAudioEngine calls the tap on its own thread.
    private nonisolated static func tapBlock(_ processor: AudioTapProcessor) -> AVAudioNodeTapBlock {
        { buffer, time in
            processor.process(buffer, time: time, receivedAt: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func observeInterruptions() {
        removeObservers()
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                              queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                self?.onInterruption?("Audio was interrupted by the system (e.g. a phone call or Siri).")
            }
        }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterruption?("Audio media services were reset by the system.") }
        }
        observers = [interruption, reset]
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}
#endif
