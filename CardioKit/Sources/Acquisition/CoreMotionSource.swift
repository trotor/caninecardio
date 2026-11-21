#if os(iOS)
import CardioCore
import CoreMotion
import Foundation

/// Raw accelerometer (g, including gravity) and gyroscope (rad/s) from `CMMotionManager`.
///
/// Raw streams are used deliberately instead of `CMDeviceMotion`, which applies sensor fusion and
/// gravity separation. The two streams have independent timestamps and are not resampled.
@MainActor
public final class CoreMotionSource: MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "CanineCardio.CoreMotion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    public init() {}

    public var isAccelerometerAvailable: Bool { manager.isAccelerometerAvailable }
    public var isGyroscopeAvailable: Bool { manager.isGyroAvailable }

    public func start(requestedRateHz: Double, capture: MotionCapture) throws {
        guard manager.isAccelerometerAvailable else { throw AcquisitionError.accelerometerUnavailable }
        let interval = 1.0 / requestedRateHz
        manager.accelerometerUpdateInterval = interval
        manager.startAccelerometerUpdates(to: queue, withHandler: Self.accelerometerHandler(capture))
        if manager.isGyroAvailable {
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: queue, withHandler: Self.gyroHandler(capture))
        }
    }

    public func stop() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
    }

    // Handlers are built in nonisolated static functions so they do not inherit main-actor
    // isolation (Core Motion calls them on `queue`, a background thread).
    private nonisolated static func accelerometerHandler(_ capture: MotionCapture) -> CMAccelerometerHandler {
        { data, error in
            guard let data else {
                if let error { capture.reportError(error.localizedDescription) }
                return
            }
            let a = data.acceleration
            capture.append(.accelerometer, Vector3Sample(t: data.timestamp, x: a.x, y: a.y, z: a.z,
                                                         receivedAt: ProcessInfo.processInfo.systemUptime))
        }
    }

    private nonisolated static func gyroHandler(_ capture: MotionCapture) -> CMGyroHandler {
        { data, error in
            guard let data else {
                if let error { capture.reportError(error.localizedDescription) }
                return
            }
            let r = data.rotationRate
            capture.append(.gyroscope, Vector3Sample(t: data.timestamp, x: r.x, y: r.y, z: r.z,
                                                     receivedAt: ProcessInfo.processInfo.systemUptime))
        }
    }
}
#endif
