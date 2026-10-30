import Foundation
import simd

/// Turns a 25 Hz accelerometer stream from a device resting on the torso into
/// breaths per minute, a breathing phase and a confidence.
///
/// Pipeline, one sample at a time:
///   1. remove gravity (exponential mean, 3 s time constant)
///   2. low-pass at 0.6 Hz, second-order Butterworth, per axis
///   3. pick the breathing axis: dominant eigenvector of the filtered covariance over 10 s
///   4. project, then find peaks and troughs with hysteresis and a 1.5 s refractory period
///   5. bpm from the median of the last four peak intervals
///
/// A motion gate on the raw signal pauses everything while the wearer moves, and a
/// confidence below `minimumConfidence` reports no bpm rather than a stale one.
final class BreathDetector {
    struct Config {
        var sampleRate = 25.0
        var gravityTau = 3.0              // s
        var lowPassHz = 0.6
        var pcaWindow = 10.0              // s
        var motionWindow = 2.0            // s
        var motionStdThreshold = 0.05     // g, std of |a| over the motion window
        var minPeakSpacing = 1.5          // s
        var hysteresisFraction = 0.3      // of recent peak-to-peak range
        var hysteresisFloor = 0.0015      // g
        var fullAmplitudeRMS = 0.003      // g RMS that counts as a strong signal
        var minimumConfidence = 0.2
        var lostAfterIntervals = 2.5      // × median interval with no peak → bpm nil
        var lostAfterSeconds = 8.0
    }

    let config: Config

    private var gravity: SIMD3<Double>?
    private var gravityAlpha: Double
    private var lp: [Biquad]

    private var filtered: Ring<SIMD3<Double>>   // after low-pass, for PCA and confidence
    private var detrended: Ring<SIMD3<Double>>  // before low-pass, for confidence
    private var magnitude: Ring<Double>         // |a| - 1, for the motion gate
    private var axis = SIMD3<Double>(0, 0, 1)
    private var samplesSinceAxisUpdate = 0

    // peak tracking on the projected signal
    private enum Direction { case rising, falling, unknown }
    private var direction = Direction.unknown
    private var extremeValue = 0.0
    private var extremeTime = 0.0
    private var lastPeakTime: Double?
    private var lastTroughTime: Double?
    private var peakIntervals: [Double] = []
    private var riseDurations: [Double] = []
    private var fallDurations: [Double] = []
    private var projected: Ring<Double>
    private var risingMeansInhale = true

    private(set) var breathCount = 0
    private(set) var lastEstimate = BreathEstimate.empty

    /// Set when the app knows the paced phase (haptic pacing) so the sign of the
    /// breathing axis can be calibrated instead of guessed from duration asymmetry.
    var externalPhaseHint: BreathPhase?

    init(config: Config = Config()) {
        self.config = config
        gravityAlpha = 1 - exp(-1 / (config.sampleRate * config.gravityTau))
        lp = (0..<3).map { _ in Biquad.lowPass(cutoffHz: config.lowPassHz, sampleRate: config.sampleRate) }
        let pcaN = Int(config.pcaWindow * config.sampleRate)
        filtered = Ring(capacity: pcaN)
        detrended = Ring(capacity: pcaN)
        projected = Ring(capacity: pcaN)
        magnitude = Ring(capacity: Int(config.motionWindow * config.sampleRate))
    }

    func reset() {
        gravity = nil
        for i in lp.indices { lp[i].reset() }
        filtered.removeAll(); detrended.removeAll(); projected.removeAll(); magnitude.removeAll()
        direction = .unknown; lastPeakTime = nil; lastTroughTime = nil
        peakIntervals.removeAll(); riseDurations.removeAll(); fallDurations.removeAll()
        breathCount = 0; samplesSinceAxisUpdate = 0
        lastEstimate = .empty
    }

    @discardableResult
    func push(_ s: AccelSample) -> BreathEstimate {
        let a = s.vector

        // 1. gravity
        if let g = gravity {
            gravity = g + gravityAlpha * (a - g)
        } else {
            gravity = a
        }
        let g = gravity!
        let d = a - g
        detrended.append(d)

        // motion gate
        magnitude.append(simd_length(a) - 1)
        let moving = motionStd() > config.motionStdThreshold

        // 2. low-pass
        let f = SIMD3(lp[0].process(d.x), lp[1].process(d.y), lp[2].process(d.z))
        filtered.append(f)

        // 3. breathing axis
        samplesSinceAxisUpdate += 1
        if filtered.isFull && samplesSinceAxisUpdate >= Int(config.sampleRate) {
            samplesSinceAxisUpdate = 0
            updateAxis()
        }
        let p = simd_dot(f, axis)
        projected.append(p)

        // 4. peaks and troughs
        if moving {
            direction = .unknown
        } else {
            trackExtremes(value: p, time: s.t)
        }

        // 5. estimate
        let conf = moving ? 0 : confidence()
        var bpm: Double?
        if !moving, conf >= config.minimumConfidence, let last = lastPeakTime, let median = medianInterval() {
            let lostAfter = max(config.lostAfterSeconds, config.lostAfterIntervals * median)
            if s.t - last <= lostAfter { bpm = 60 / median }
        }
        var phase = BreathPhase.unknown
        if bpm != nil {
            switch direction {
            case .rising: phase = risingMeansInhale ? .inhale : .exhale
            case .falling: phase = risingMeansInhale ? .exhale : .inhale
            case .unknown: phase = .unknown
            }
        }
        let est = BreathEstimate(t: s.t, level: p, bpm: bpm, phase: phase, confidence: conf,
                                 isMoving: moving, breathCount: breathCount, gravity: g)
        lastEstimate = est
        return est
    }

    // MARK: - internals

    private func motionStd() -> Double {
        let xs = magnitude.elements
        guard xs.count >= 10 else { return 0 }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return v.squareRoot()
    }

    /// Dominant eigenvector of the 3×3 covariance by power iteration, seeded with the
    /// previous axis so the sign stays continuous.
    private func updateAxis() {
        let xs = filtered.elements
        let n = Double(xs.count)
        let mean = xs.reduce(SIMD3<Double>(repeating: 0), +) / n
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for v in xs {
            let d = v - mean
            for i in 0..<3 { for j in 0..<3 { c[i][j] += d[i] * d[j] } }
        }
        var v = axis
        for _ in 0..<25 {
            let w = SIMD3(c[0][0] * v.x + c[0][1] * v.y + c[0][2] * v.z,
                          c[1][0] * v.x + c[1][1] * v.y + c[1][2] * v.z,
                          c[2][0] * v.x + c[2][1] * v.y + c[2][2] * v.z)
            let len = simd_length(w)
            if len < 1e-12 { return }
            v = w / len
        }
        if simd_dot(v, axis) < 0 { v = -v }
        axis = v
    }

    private func recentRange() -> Double {
        let xs = projected.elements
        guard let lo = xs.min(), let hi = xs.max() else { return 0 }
        return hi - lo
    }

    private func trackExtremes(value p: Double, time t: Double) {
        let h = max(config.hysteresisFloor, config.hysteresisFraction * recentRange())
        switch direction {
        case .unknown:
            direction = .rising
            extremeValue = p; extremeTime = t
        case .rising:
            if p > extremeValue { extremeValue = p; extremeTime = t }
            else if extremeValue - p > h { confirmPeak(at: extremeTime); direction = .falling; extremeValue = p; extremeTime = t }
        case .falling:
            if p < extremeValue { extremeValue = p; extremeTime = t }
            else if p - extremeValue > h { confirmTrough(at: extremeTime); direction = .rising; extremeValue = p; extremeTime = t }
        }
    }

    private func confirmPeak(at t: Double) {
        if let last = lastPeakTime {
            let dt = t - last
            guard dt >= config.minPeakSpacing else { return }
            peakIntervals.append(dt)
            if peakIntervals.count > 6 { peakIntervals.removeFirst() }
            breathCount += 1
        }
        if let trough = lastTroughTime { riseDurations.append(t - trough) }
        if riseDurations.count > 6 { riseDurations.removeFirst() }
        lastPeakTime = t
        updateSign()
    }

    private func confirmTrough(at t: Double) {
        if let peak = lastPeakTime { fallDurations.append(t - peak) }
        if fallDurations.count > 6 { fallDurations.removeFirst() }
        lastTroughTime = t
    }

    /// Resting exhale is usually longer than inhale, so the shorter half-cycle is taken
    /// as the inhale unless the app tells us the paced phase directly.
    private func updateSign() {
        if let hint = externalPhaseHint, direction != .unknown {
            // at a confirmed peak we are about to fall; if the pacer says we should be inhaling now,
            // then falling means inhale.
            risingMeansInhale = (hint == .exhale)
            return
        }
        guard riseDurations.count >= 3, fallDurations.count >= 3 else { return }
        let rise = riseDurations.reduce(0, +) / Double(riseDurations.count)
        let fall = fallDurations.reduce(0, +) / Double(fallDurations.count)
        risingMeansInhale = rise <= fall
    }

    private func medianInterval() -> Double? {
        guard peakIntervals.count >= 2 else { return nil }
        let s = peakIntervals.suffix(4).sorted()
        let m = s.count
        return m % 2 == 1 ? s[m / 2] : (s[m / 2 - 1] + s[m / 2]) / 2
    }

    /// Band power of the filtered projection over the detrended projection, times an
    /// amplitude factor so a quiet desk never looks like a quiet breather.
    private func confidence() -> Double {
        let f = projected.elements
        guard f.count >= Int(config.sampleRate * 4) else { return 0 }
        let r = detrended.elements.map { simd_dot($0, axis) }
        func rms(_ xs: [Double]) -> Double {
            let m = xs.reduce(0, +) / Double(xs.count)
            return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
        }
        let rf = rms(f), rr = rms(r)
        guard rr > 1e-9 else { return 0 }
        let band = min(1, (rf * rf) / (rr * rr))
        let amp = min(1, rf / config.fullAmplitudeRMS)
        return max(0, min(1, band * amp))
    }
}
