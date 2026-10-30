import Foundation

/// Anything that produces accelerometer samples at about 25 Hz.
/// `onSample` may be called on any queue.
protocol MotionSource: AnyObject {
    var name: String { get }
    var isAvailable: Bool { get }
    var onSample: ((AccelSample) -> Void)? { get set }
    func start()
    func stop()
}

/// Anything that can play a haptic amplitude from 0 to 1.
protocol HapticSink: AnyObject {
    var name: String { get }
    var isReady: Bool { get }
    func startHaptics()
    func stopHaptics()
    func setAmplitude(_ amplitude: Double)
}
