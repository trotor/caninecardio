import CardioCore
import Foundation
import Synchronization

/// The time window (uptime seconds) whose samples are written to the recording.
///
/// Sensors may run before the window opens (live preview, start delay) and briefly after it
/// closes (late delivery); only samples whose *sensor timestamp* lies inside the window are kept.
/// Motion and audio share one gate so both streams cover the same interval.
public final class CaptureGate: Sendable {
    private let window = Mutex<ClosedRange<Double>?>(nil)

    public init() {}

    public func open(start: Double, end: Double) {
        window.withLock { $0 = start...max(start, end) }
    }

    /// Moves the end earlier (user pressed Stop). Never extends the window.
    public func close(at end: Double) {
        window.withLock { w in
            guard let current = w else { return }
            w = current.lowerBound...max(current.lowerBound, min(current.upperBound, end))
        }
    }

    public func clear() { window.withLock { $0 = nil } }

    public var current: ClosedRange<Double>? { window.withLock { $0 } }
}

/// Receives motion samples from sensor callbacks.
///
/// `append` is called on the Core Motion queue at ~100 Hz per sensor. It takes a lock, writes
/// into pre-reserved arrays and the live ring buffer, and never touches disk or the UI.
public final class MotionCapture: Sendable {
    public let gate: CaptureGate
    public let accelerometerLive: LiveRingBuffer
    public let gyroscopeLive: LiveRingBuffer

    private struct State {
        var accelerometer: [Vector3Sample] = []
        var gyroscope: [Vector3Sample] = []
        var receivedAccelerometer = 0
        var receivedGyroscope = 0
        var lastError: String?
    }

    private let state: Mutex<State>

    /// - Parameter expectedSamplesPerSensor: capacity reserved up front so that appends during
    ///   recording do not reallocate.
    public init(gate: CaptureGate, expectedSamplesPerSensor: Int, liveCapacity: Int = 1500) {
        self.gate = gate
        var s = State()
        s.accelerometer.reserveCapacity(expectedSamplesPerSensor)
        s.gyroscope.reserveCapacity(expectedSamplesPerSensor)
        state = Mutex(s)
        accelerometerLive = LiveRingBuffer(capacity: liveCapacity, channelCount: 3)
        gyroscopeLive = LiveRingBuffer(capacity: liveCapacity, channelCount: 3)
    }

    public func append(_ kind: MotionSensorKind, _ sample: Vector3Sample) {
        switch kind {
        case .accelerometer: accelerometerLive.append(t: sample.t, sample.x, sample.y, sample.z)
        case .gyroscope: gyroscopeLive.append(t: sample.t, sample.x, sample.y, sample.z)
        }
        let inWindow = gate.current?.contains(sample.t) ?? false
        state.withLock { s in
            switch kind {
            case .accelerometer:
                s.receivedAccelerometer += 1
                if inWindow { s.accelerometer.append(sample) }
            case .gyroscope:
                s.receivedGyroscope += 1
                if inWindow { s.gyroscope.append(sample) }
            }
        }
    }

    public func reportError(_ message: String) {
        state.withLock { $0.lastError = message }
    }

    public struct Counts: Sendable, Equatable {
        public var recordedAccelerometer: Int
        public var recordedGyroscope: Int
        public var receivedAccelerometer: Int
        public var receivedGyroscope: Int
        public var lastError: String?
    }

    public var counts: Counts {
        state.withLock {
            Counts(recordedAccelerometer: $0.accelerometer.count, recordedGyroscope: $0.gyroscope.count,
                   receivedAccelerometer: $0.receivedAccelerometer, receivedGyroscope: $0.receivedGyroscope,
                   lastError: $0.lastError)
        }
    }

    /// Returns the recorded samples sorted by timestamp and clears the recording buffers.
    public func takeRecorded() -> (accelerometer: [Vector3Sample], gyroscope: [Vector3Sample]) {
        let (a, g) = state.withLock { s in
            let out = (s.accelerometer, s.gyroscope)
            s.accelerometer.removeAll(keepingCapacity: true)
            s.gyroscope.removeAll(keepingCapacity: true)
            return out
        }
        // Core Motion delivers in order, but sort defensively (stable for equal timestamps).
        return (Self.sortedIfNeeded(a), Self.sortedIfNeeded(g))
    }

    public func resetCounts() {
        state.withLock {
            $0.receivedAccelerometer = 0
            $0.receivedGyroscope = 0
            $0.lastError = nil
        }
        accelerometerLive.reset()
        gyroscopeLive.reset()
    }

    private static func sortedIfNeeded(_ v: [Vector3Sample]) -> [Vector3Sample] {
        for i in v.indices.dropFirst() where v[i].t < v[i - 1].t {
            return v.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        }
        return v
    }
}
