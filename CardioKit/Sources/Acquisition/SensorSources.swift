import CardioCore
import Foundation

/// A source of raw motion samples (Core Motion on device; fakes in tests and previews).
@MainActor
public protocol MotionSource: AnyObject {
    var isAccelerometerAvailable: Bool { get }
    var isGyroscopeAvailable: Bool { get }
    /// Starts delivering samples into `capture`. Called once per preview/recording run.
    func start(requestedRateHz: Double, capture: MotionCapture) throws
    func stop()
}

public struct AudioInputInfo: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var inputLatencyS: Double?
    public var ioBufferDurationS: Double?
    public var sessionMode: String
    public var portName: String?
    public var dataSource: String?

    public init(sampleRate: Double, channelCount: Int, inputLatencyS: Double? = nil,
                ioBufferDurationS: Double? = nil, sessionMode: String, portName: String? = nil,
                dataSource: String? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.inputLatencyS = inputLatencyS
        self.ioBufferDurationS = ioBufferDurationS
        self.sessionMode = sessionMode
        self.portName = portName
        self.dataSource = dataSource
    }
}

/// A source of raw microphone audio.
@MainActor
public protocol AudioSource: AnyObject {
    /// Starts the input; envelope goes to `live`. Frames inside `gate` go to the file once opened.
    func start(live: LiveRingBuffer, gate: CaptureGate) throws -> AudioInputInfo
    func openFile(url: URL) throws
    func closeFile() -> AudioTapProcessor.FileSummary?
    func stop()
    var framesWritten: Int64 { get }
    /// Called on the main actor when the system interrupts audio (phone call, Siri, ...).
    var onInterruption: (@MainActor (String) -> Void)? { get set }
}
