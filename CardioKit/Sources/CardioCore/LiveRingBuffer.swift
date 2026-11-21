import Foundation
import Synchronization

/// Fixed-capacity, thread-safe ring buffer for live display.
///
/// Writers (sensor callbacks) call `append`, which never allocates: all storage is created up
/// front. Readers (the UI, at display rate) take a `snapshot`, which copies the requested window.
public final class LiveRingBuffer: Sendable {
    public let capacity: Int
    public let channelCount: Int

    private struct State {
        var times: [Double]
        var values: [Double]      // channel-major: values[ch * capacity + i]
        var head = 0              // next write position
        var count = 0
        var totalAppended = 0
    }

    private let state: Mutex<State>

    public init(capacity: Int, channelCount: Int) {
        precondition(capacity > 0 && (1...3).contains(channelCount))
        self.capacity = capacity
        self.channelCount = channelCount
        state = Mutex(State(times: Array(repeating: 0, count: capacity),
                            values: Array(repeating: 0, count: capacity * channelCount)))
    }

    public func append(t: Double, _ a: Double, _ b: Double = 0, _ c: Double = 0) {
        let cap = capacity
        let channels = channelCount
        state.withLock { s in
            let i = s.head
            s.times[i] = t
            s.values[i] = a
            if channels > 1 { s.values[cap + i] = b }
            if channels > 2 { s.values[2 * cap + i] = c }
            s.head = (i + 1) % cap
            s.count = min(s.count + 1, cap)
            s.totalAppended += 1
        }
    }

    public func reset() {
        state.withLock { s in
            s.head = 0
            s.count = 0
            s.totalAppended = 0
        }
    }

    public var totalAppended: Int { state.withLock { $0.totalAppended } }

    /// Timestamp of the most recently appended sample.
    public var latestTime: Double? {
        let cap = capacity
        return state.withLock { s in s.count == 0 ? nil : s.times[(s.head - 1 + cap) % cap] }
    }

    /// Copies samples with `t >= since` (oldest first).
    public func snapshot(since: Double = -.infinity) -> LiveSnapshot {
        let cap = capacity
        let channels = channelCount
        return state.withLock { s in
            var times = [Double]()
            var chans = Array(repeating: [Double](), count: channels)
            times.reserveCapacity(s.count)
            for ch in 0..<channels { chans[ch].reserveCapacity(s.count) }
            let start = (s.head - s.count + cap) % cap
            for k in 0..<s.count {
                let i = (start + k) % cap
                let t = s.times[i]
                guard t >= since else { continue }
                times.append(t)
                for ch in 0..<channels { chans[ch].append(s.values[ch * cap + i]) }
            }
            return LiveSnapshot(times: times, channels: chans)
        }
    }
}

public struct LiveSnapshot: Sendable, Equatable {
    public var times: [Double]
    public var channels: [[Double]]

    public init(times: [Double], channels: [[Double]]) {
        self.times = times
        self.channels = channels
    }

    public var isEmpty: Bool { times.isEmpty }

    /// Min/max decimation to at most `2 * buckets` points per channel, preserving peaks.
    public func decimated(buckets: Int) -> LiveSnapshot {
        guard times.count > 2 * buckets, buckets > 0 else { return self }
        let n = times.count
        var outT = [Double]()
        var outC = Array(repeating: [Double](), count: channels.count)
        outT.reserveCapacity(2 * buckets)
        for b in 0..<buckets {
            let lo = b * n / buckets
            let hi = max(lo + 1, (b + 1) * n / buckets)
            // Use the first channel to choose the min and max indices so channels stay aligned.
            var iMin = lo, iMax = lo
            for i in lo..<hi {
                if channels[0][i] < channels[0][iMin] { iMin = i }
                if channels[0][i] > channels[0][iMax] { iMax = i }
            }
            for i in [min(iMin, iMax), max(iMin, iMax)] {
                outT.append(times[i])
                for ch in channels.indices { outC[ch].append(channels[ch][i]) }
            }
        }
        return LiveSnapshot(times: outT, channels: outC)
    }
}

/// Simple operator-facing indicator of how much the phone is moving.
///
/// This is *not* a cardiac signal-quality measure; it only tells the operator whether the
/// recording is dominated by gross motion (handling, the dog shifting, panting).
public enum MotionLevel: String, Sendable {
    case unknown, still, slight, moving

    /// Classifies the standard deviation of acceleration magnitude (g) over a short window.
    public static func classify(magnitudeStdG std: Double?) -> MotionLevel {
        guard let std, std.isFinite else { return .unknown }
        switch std {
        case ..<0.004: return .still
        case ..<0.02: return .slight
        default: return .moving
        }
    }
}
