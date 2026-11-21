import Foundation

/// One three-axis motion sample.
///
/// `t` is the sensor timestamp in seconds on the device's monotonic uptime clock
/// (`CMLogItem.timestamp`, the same mach-absolute-time base as `ProcessInfo.systemUptime`
/// and `AVAudioTime.hostTime`). `receivedAt` is the uptime at which the sample was
/// delivered to the app; `receivedAt - t` is the callback delivery latency.
public struct Vector3Sample: Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var z: Double
    public var receivedAt: Double

    public init(t: Double, x: Double, y: Double, z: Double, receivedAt: Double? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.z = z
        self.receivedAt = receivedAt ?? t
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

public enum MotionSensorKind: String, Codable, Sendable, CaseIterable {
    case accelerometer
    case gyroscope

    /// Units as delivered by Core Motion.
    public var units: String {
        switch self {
        case .accelerometer: "g"
        case .gyroscope: "rad/s"
        }
    }

    public var fileName: String { "\(rawValue).csv" }
}

public enum MotionAxis: String, Codable, Sendable, CaseIterable, Identifiable {
    case x, y, z, magnitude
    public var id: String { rawValue }

    public func value(of s: Vector3Sample) -> Double {
        switch self {
        case .x: s.x
        case .y: s.y
        case .z: s.z
        case .magnitude: s.magnitude
        }
    }
}

/// A recorded motion stream: samples in arrival order, timestamps not assumed uniform.
public struct MotionSeries: Sendable, Equatable {
    public var kind: MotionSensorKind
    public var samples: [Vector3Sample]

    public init(kind: MotionSensorKind, samples: [Vector3Sample]) {
        self.kind = kind
        self.samples = samples
    }

    public var timestamps: [Double] { samples.map(\.t) }
    public func values(_ axis: MotionAxis) -> [Double] { samples.map { axis.value(of: $0) } }
}
