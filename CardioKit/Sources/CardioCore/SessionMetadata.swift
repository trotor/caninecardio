import Foundation

/// Everything needed to interpret a recorded session folder, stored as `metadata.json`.
///
/// Timing model (see docs/SYNCHRONIZATION.md):
/// * All motion timestamps are on the monotonic uptime clock (seconds since boot, excluding sleep).
/// * `referenceUptimeS` is the uptime that relative time `t_rel_s = 0` corresponds to.
/// * Audio timing is sample-based: frame `k` is at
///   `audio.firstFrameUptimeS + (k / sampleRateHz)` on the same clock, with the documented
///   uncertainty of the host-time stamp and input latency. Raw values are stored, not corrected.
public struct SessionMetadata: Codable, Sendable, Equatable, Identifiable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    /// `true` for generated data. Synthetic sessions must never be mistaken for measurements.
    public var isSynthetic: Bool
    public var syntheticDescription: String?
    public var createdAt: Date
    /// Free-text label entered by the operator (e.g. subject name, posture).
    public var label: String
    public var requestedDurationS: Double
    public var recordedDurationS: Double
    public var endReason: EndReason
    public var referenceUptimeS: Double
    public var clockDescription: String
    public var requestedMotionRateHz: Double
    public var accelerometer: MotionStreamInfo?
    public var gyroscope: MotionStreamInfo?
    public var audio: AudioStreamInfo?
    public var device: DeviceInfo
    public var appVersion: String
    /// Human-readable warnings collected during recording (e.g. audio disabled).
    public var notes: [String]

    public enum EndReason: String, Codable, Sendable {
        case completed, stoppedByUser, interrupted, failed
    }

    public init(id: String, isSynthetic: Bool, syntheticDescription: String? = nil, createdAt: Date,
                label: String, requestedDurationS: Double, recordedDurationS: Double,
                endReason: EndReason, referenceUptimeS: Double, requestedMotionRateHz: Double,
                accelerometer: MotionStreamInfo?, gyroscope: MotionStreamInfo?,
                audio: AudioStreamInfo?, device: DeviceInfo, appVersion: String, notes: [String]) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.isSynthetic = isSynthetic
        self.syntheticDescription = syntheticDescription
        self.createdAt = createdAt
        self.label = label
        self.requestedDurationS = requestedDurationS
        self.recordedDurationS = recordedDurationS
        self.endReason = endReason
        self.referenceUptimeS = referenceUptimeS
        self.clockDescription = Self.clockDescriptionText
        self.requestedMotionRateHz = requestedMotionRateHz
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.audio = audio
        self.device = device
        self.appVersion = appVersion
        self.notes = notes
    }

    public static let clockDescriptionText =
        "Monotonic seconds since boot (mach_absolute_time base; excludes device sleep). Shared by CMLogItem.timestamp, ProcessInfo.systemUptime and AVAudioTime.hostTime."
}

public struct MotionStreamInfo: Codable, Sendable, Equatable {
    public var fileName: String
    public var units: String
    public var sampling: SamplingStatistics
    public var firstUptimeS: Double?
    public var lastUptimeS: Double?
    /// Median of (delivery uptime - sensor timestamp), seconds. A large or negative value
    /// would indicate that the sensor timestamps are not on the uptime clock.
    public var medianDeliveryLatencyS: Double?

    public init(fileName: String, units: String, sampling: SamplingStatistics, firstUptimeS: Double?,
                lastUptimeS: Double?, medianDeliveryLatencyS: Double?) {
        self.fileName = fileName
        self.units = units
        self.sampling = sampling
        self.firstUptimeS = firstUptimeS
        self.lastUptimeS = lastUptimeS
        self.medianDeliveryLatencyS = medianDeliveryLatencyS
    }

    public static func summarize(_ series: MotionSeries) -> MotionStreamInfo {
        let t = series.timestamps
        let latency = series.samples.isEmpty ? nil : Statistics.median(series.samples.map { $0.receivedAt - $0.t })
        return MotionStreamInfo(fileName: series.kind.fileName, units: series.kind.units,
                                sampling: .compute(timestamps: t), firstUptimeS: t.first,
                                lastUptimeS: t.last, medianDeliveryLatencyS: latency)
    }
}

public struct AudioStreamInfo: Codable, Sendable, Equatable {
    public var fileName: String
    public var fileFormat: String
    public var sampleRateHz: Double
    public var channelCount: Int
    public var frameCount: Int64
    /// Uptime of the first written frame, derived from the tap buffer's `AVAudioTime.hostTime`.
    /// Frame k of the file is at `firstFrameUptimeS + k / sampleRateHz`.
    public var firstFrameUptimeS: Double?
    /// `AVAudioTime.sampleTime` of the first written frame.
    public var firstFrameSampleTime: Int64?
    /// Host-clock vs sample-clock drift over the recording, parts per million
    /// (positive: host clock advanced more than frames/sampleRate). `nil` if not measurable.
    public var sampleClockDriftPPM: Double?
    /// Number of buffers whose sampleTime did not continue from the previous buffer.
    public var sampleTimeDiscontinuities: Int
    /// Frames lost in those discontinuities (positive jumps only).
    public var discontinuityFrames: Int64
    /// `AVAudioSession.inputLatency` at start, seconds. Not applied to timestamps.
    public var inputLatencyS: Double?
    /// `AVAudioSession.ioBufferDuration` at start, seconds.
    public var ioBufferDurationS: Double?
    public var sessionMode: String
    public var inputPortName: String?
    public var inputDataSource: String?
    public var medianBufferDeliveryLatencyS: Double?

    public init(fileName: String, fileFormat: String, sampleRateHz: Double, channelCount: Int,
                frameCount: Int64, firstFrameUptimeS: Double?, firstFrameSampleTime: Int64?,
                sampleClockDriftPPM: Double?, sampleTimeDiscontinuities: Int, discontinuityFrames: Int64, inputLatencyS: Double?,
                ioBufferDurationS: Double?, sessionMode: String, inputPortName: String?,
                inputDataSource: String?, medianBufferDeliveryLatencyS: Double?) {
        self.fileName = fileName
        self.fileFormat = fileFormat
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.firstFrameUptimeS = firstFrameUptimeS
        self.firstFrameSampleTime = firstFrameSampleTime
        self.sampleClockDriftPPM = sampleClockDriftPPM
        self.sampleTimeDiscontinuities = sampleTimeDiscontinuities
        self.discontinuityFrames = discontinuityFrames
        self.inputLatencyS = inputLatencyS
        self.ioBufferDurationS = ioBufferDurationS
        self.sessionMode = sessionMode
        self.inputPortName = inputPortName
        self.inputDataSource = inputDataSource
        self.medianBufferDeliveryLatencyS = medianBufferDeliveryLatencyS
    }

    public var durationS: Double { sampleRateHz > 0 ? Double(frameCount) / sampleRateHz : 0 }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var modelIdentifier: String
    public var systemName: String
    public var systemVersion: String

    public init(modelIdentifier: String, systemName: String, systemVersion: String) {
        self.modelIdentifier = modelIdentifier
        self.systemName = systemName
        self.systemVersion = systemVersion
    }

    /// Hardware identifier such as "iPhone15,4" (from `uname`), plus OS version.
    public static func current(systemName: String, systemVersion: String) -> DeviceInfo {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return DeviceInfo(modelIdentifier: machine, systemName: systemName, systemVersion: systemVersion)
    }
}
