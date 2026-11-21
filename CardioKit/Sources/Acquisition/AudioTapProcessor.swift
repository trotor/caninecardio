@preconcurrency import AVFoundation
import Accelerate
import CardioCore
import Foundation
import Synchronization

/// Handles microphone buffers delivered by an `AVAudioEngine` input tap.
///
/// Platform-independent so it can be unit tested with synthetic buffers. For each buffer it:
/// 1. converts the buffer's host time to uptime seconds (sample-based timing within the buffer),
/// 2. checks `sampleTime` continuity and counts discontinuities,
/// 3. pushes a 10 ms RMS / peak envelope into the live ring buffer,
/// 4. writes exactly the frames that fall inside the capture gate to the WAV file.
///
/// The tap is called roughly every 100 ms (not a high-frequency callback), on a non-realtime
/// thread; file writes happen here under a lock so `closeFile` cannot race a write.
public final class AudioTapProcessor: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let live: LiveRingBuffer
    public let gate: CaptureGate
    /// Converts an `AVAudioTime.hostTime` to uptime seconds. Injectable for tests.
    private let hostTimeToSeconds: @Sendable (UInt64) -> Double

    private struct State {
        var file: AVAudioFile?
        var fileName = ""
        var framesWritten: Int64 = 0
        var firstFrameUptime: Double?
        var firstFrameSampleTime: Int64?
        var lastBufferUptime: Double?
        var lastBufferFrameIndex: Int64 = 0
        var expectedNextSampleTime: Int64?
        var discontinuities = 0
        var discontinuityFrames: Int64 = 0
        var deliveryLatencies: [Double] = []
        var writeError: String?
    }

    private let state = Mutex(State())

    public init(sampleRate: Double, channelCount: Int, live: LiveRingBuffer, gate: CaptureGate,
                hostTimeToSeconds: @escaping @Sendable (UInt64) -> Double = { AVAudioTime.seconds(forHostTime: $0) }) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.live = live
        self.gate = gate
        self.hostTimeToSeconds = hostTimeToSeconds
    }

    /// WAV, IEEE float32, non-processed microphone samples.
    public static let fileFormatDescription = "WAV (RIFF), 32-bit IEEE float, little-endian"

    public func openFile(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw AcquisitionError.audioFileFailed(error.localizedDescription)
        }
        let name = url.lastPathComponent
        state.withLock { s in
            s = State()
            s.file = file
            s.fileName = name
            s.deliveryLatencies.reserveCapacity(4096)
        }
    }

    /// Process one tap buffer. `receivedAt` is the uptime when the tap block ran.
    public func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, receivedAt: Double) {
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else { return }
        let fs = sampleRate
        let start = time.isHostTimeValid ? hostTimeToSeconds(time.hostTime) : receivedAt - Double(n) / fs
        let sampleTime: Int64? = time.isSampleTimeValid ? time.sampleTime : nil

        // Live envelope of channel 0: 10 ms RMS and peak.
        let chunk = max(1, Int(fs / 100))
        var offset = 0
        while offset < n {
            let len = min(chunk, n - offset)
            var rms: Float = 0
            var peak: Float = 0
            vDSP_rmsqv(channels[0] + offset, 1, &rms, vDSP_Length(len))
            vDSP_maxmgv(channels[0] + offset, 1, &peak, vDSP_Length(len))
            live.append(t: start + (Double(offset) + Double(len) / 2) / fs, Double(rms), Double(peak))
            offset += len
        }

        let window = gate.current
        state.withLock { s in
            guard let file = s.file, let window else { return }
            // Frames [a, b) of this buffer lie in [gate start, gate end). The small tolerance keeps
            // floating-point error from adding or dropping a frame exactly at the edges.
            let a = Self.clampIndex(((window.lowerBound - start) * fs - 1e-6).rounded(.up), n)
            let b = Self.clampIndex(((window.upperBound - start) * fs - 1e-6).rounded(.up), n)
            guard b > a else { return }

            if let sampleTime {
                if let expected = s.expectedNextSampleTime, sampleTime != expected, s.framesWritten > 0 {
                    s.discontinuities += 1
                    s.discontinuityFrames += max(0, sampleTime - expected)
                }
                s.expectedNextSampleTime = sampleTime + Int64(n)
            }
            if s.firstFrameUptime == nil {
                s.firstFrameUptime = start + Double(a) / fs
                s.firstFrameSampleTime = sampleTime.map { $0 + Int64(a) }
            }
            s.lastBufferUptime = start + Double(a) / fs
            s.lastBufferFrameIndex = s.framesWritten
            if s.deliveryLatencies.count < s.deliveryLatencies.capacity {
                s.deliveryLatencies.append(receivedAt - start)
            }
            do {
                if a == 0 && b == n {
                    try file.write(from: buffer)
                } else if let slice = Self.slice(buffer, from: a, to: b) {
                    try file.write(from: slice)   // only at the two gate edges
                }
                s.framesWritten += Int64(b - a)
            } catch {
                s.writeError = error.localizedDescription
            }
        }
    }

    public struct FileSummary: Sendable, Equatable {
        public var fileName: String
        public var framesWritten: Int64
        public var firstFrameUptime: Double?
        public var firstFrameSampleTime: Int64?
        public var discontinuities: Int
        public var discontinuityFrames: Int64
        public var driftPPM: Double?
        public var medianDeliveryLatency: Double?
        public var writeError: String?
    }

    public var framesWritten: Int64 { state.withLock { $0.framesWritten } }

    /// Closes the file (finalising the WAV header) and summarises what was written.
    public func closeFile() -> FileSummary? {
        let fs = sampleRate
        return state.withLock { s in
            guard let file = s.file else { return nil }
            file.close()
            s.file = nil
            var drift: Double?
            if let first = s.firstFrameUptime, let last = s.lastBufferUptime, s.discontinuities == 0,
               s.lastBufferFrameIndex > Int64(fs) {
                let sampleClock = Double(s.lastBufferFrameIndex) / fs
                drift = ((last - first) - sampleClock) / sampleClock * 1e6
            }
            return FileSummary(
                fileName: s.fileName, framesWritten: s.framesWritten, firstFrameUptime: s.firstFrameUptime,
                firstFrameSampleTime: s.firstFrameSampleTime, discontinuities: s.discontinuities,
                discontinuityFrames: s.discontinuityFrames, driftPPM: drift,
                medianDeliveryLatency: s.deliveryLatencies.isEmpty ? nil : Statistics.median(s.deliveryLatencies),
                writeError: s.writeError)
        }
    }

    private static func clampIndex(_ v: Double, _ n: Int) -> Int {
        guard v.isFinite else { return v > 0 ? n : 0 }
        return Int(min(Double(n), max(0, v)))
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, from a: Int, to b: Int) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(b - a)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for ch in 0..<Int(buffer.format.channelCount) {
            (dst[ch]).update(from: src[ch] + a, count: b - a)
        }
        out.frameLength = AVAudioFrameCount(b - a)
        return out
    }
}
