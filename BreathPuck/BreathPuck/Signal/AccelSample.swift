import Foundation

/// One accelerometer reading in g. `t` is seconds on a monotonic clock
/// (CoreMotion's timestamp, or system uptime for puck packets).
struct AccelSample: Sendable, Equatable {
    var t: TimeInterval
    var x: Double
    var y: Double
    var z: Double

    var vector: SIMD3<Double> { SIMD3(x, y, z) }
}

enum BreathPhase: String, Sendable {
    case inhale, exhale, unknown
}

/// What the detector believes right now. Emitted once per input sample.
struct BreathEstimate: Sendable {
    var t: TimeInterval
    /// Filtered chest-motion signal projected on the breathing axis, in g.
    var level: Double
    /// Breaths per minute from the last few intervals, nil when nothing credible is seen
    /// (off body, breath hold, moving, or still warming up).
    var bpm: Double?
    var phase: BreathPhase
    /// 0...1. Share of the signal that sits in the breathing band, scaled by how large it is.
    var confidence: Double
    /// True while whole-body motion swamps the signal; detection is paused.
    var isMoving: Bool
    var breathCount: Int
    /// Low-passed gravity direction, for guessing where the device is clipped.
    var gravity: SIMD3<Double>

    static let empty = BreathEstimate(t: 0, level: 0, bpm: nil, phase: .unknown, confidence: 0,
                                      isMoving: false, breathCount: 0, gravity: SIMD3(0, 0, -1))
}
