import Foundation
import CoreMotion

/// The phone's own accelerometer. Lay the phone flat on your chest or belly and
/// it is the same signal the puck will send, so the whole pipeline can be tuned
/// before any hardware exists.
final class PhoneMotionSource: MotionSource {
    let name = "iPhone on chest"
    var onSample: ((AccelSample) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "BreathPuck.phoneMotion"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    var isAvailable: Bool { manager.isAccelerometerAvailable }

    func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 25.0
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let d = data else { return }
            // CMAcceleration is already in g.
            self.onSample?(AccelSample(t: d.timestamp, x: d.acceleration.x, y: d.acceleration.y, z: d.acceleration.z))
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
    }
}
