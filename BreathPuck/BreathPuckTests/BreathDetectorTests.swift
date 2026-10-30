import Testing
import Foundation
@testable import BreathPuck

/// Synthetic chest signals. Gravity sits mostly on -y (phone upright-ish on a chest),
/// breathing tilts the z axis by a few milli-g, and a little white noise rides on top.
private struct ChestSimulator {
    var sampleRate = 25.0
    var breathingAmplitudeG = 0.010
    var noiseG = 0.002
    var gravity = SIMD3<Double>(0.05, -0.95, 0.31)
    private var rng: UInt64 = 0x9E3779B97F4A7C15

    private mutating func gaussian() -> Double {
        // Box-Muller on an xorshift generator, deterministic across runs
        func next(_ s: inout UInt64) -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s >> 11) / Double(1 << 53)
        }
        let u1 = max(1e-12, next(&rng)), u2 = next(&rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Feed `seconds` of signal into the detector. `bpm` nil means no breathing.
    /// `walking` adds a 2 Hz, 0.3 g bounce.
    mutating func run(_ d: BreathDetector, seconds: Double, bpm: Double?, walking: Bool = false,
                      startTime: Double = 0) -> BreathEstimate {
        var est = BreathEstimate.empty
        let n = Int(seconds * sampleRate)
        for i in 0..<n {
            let t = startTime + Double(i) / sampleRate
            var a = gravity
            if let bpm {
                // asymmetric breath: quick-ish inhale, slower exhale, like a resting person
                let phase = (t * bpm / 60).truncatingRemainder(dividingBy: 1)
                let shaped = phase < 0.4 ? sin(.pi * phase / 0.4 / 2) : cos(.pi * (phase - 0.4) / 0.6 / 2)
                a.z += breathingAmplitudeG * shaped
            }
            if walking {
                a.y += 0.3 * sin(2 * .pi * 2 * t)
                a.x += 0.1 * sin(2 * .pi * 2 * t + 1)
            }
            a += SIMD3(gaussian(), gaussian(), gaussian()) * noiseG
            est = d.push(AccelSample(t: t, x: a.x, y: a.y, z: a.z))
        }
        return est
    }
}

@Suite("Breath detector")
struct BreathDetectorTests {

    @Test("Resting breathing at 12 bpm is read within one breath per minute")
    func restingTwelve() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        let est = sim.run(d, seconds: 90, bpm: 12)
        #expect(est.bpm != nil)
        if let bpm = est.bpm { #expect(abs(bpm - 12) <= 1.0, "got \(bpm)") }
        #expect(est.confidence > 0.5, "confidence \(est.confidence)")
        #expect(!est.isMoving)
        #expect(est.phase != .unknown)
        // 90 s at 12 bpm is 18 breaths; the first few are warm-up
        #expect(est.breathCount >= 13 && est.breathCount <= 19, "count \(est.breathCount)")
    }

    @Test("Fast breathing at 20 bpm is read as 20, not as a default")
    func fastTwenty() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        let est = sim.run(d, seconds: 90, bpm: 20)
        #expect(est.bpm != nil)
        if let bpm = est.bpm { #expect(abs(bpm - 20) <= 1.5, "got \(bpm)") }
    }

    @Test("Slow paced breathing at 5.5 bpm is read")
    func coherentRate() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        let est = sim.run(d, seconds: 120, bpm: 5.5)
        #expect(est.bpm != nil)
        if let bpm = est.bpm { #expect(abs(bpm - 5.5) <= 0.7, "got \(bpm)") }
    }

    @Test("A still device with no breathing reports nothing")
    func offBody() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        let est = sim.run(d, seconds: 60, bpm: nil)
        #expect(est.bpm == nil, "bpm should be nil, got \(String(describing: est.bpm))")
        #expect(est.confidence < 0.2, "confidence \(est.confidence)")
        #expect(!est.isMoving)
    }

    @Test("Holding the breath drops the rate instead of freezing it")
    func breathHold() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        let before = sim.run(d, seconds: 60, bpm: 12)
        #expect(before.bpm != nil)
        let after = sim.run(d, seconds: 25, bpm: nil, startTime: 60)
        #expect(after.bpm == nil, "bpm after a 25 s hold should be nil, got \(String(describing: after.bpm))")
    }

    @Test("Walking trips the motion gate and suppresses the rate")
    func walking() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        _ = sim.run(d, seconds: 40, bpm: 12)
        let est = sim.run(d, seconds: 10, bpm: 12, walking: true, startTime: 40)
        #expect(est.isMoving)
        #expect(est.bpm == nil)
        #expect(est.confidence == 0)
    }

    @Test("Mutation check: a detector fed the signal on a different axis still finds it")
    func axisAgnostic() {
        var sim = ChestSimulator()
        sim.gravity = SIMD3(0.98, 0.1, 0.15)   // device sideways; breathing still on z
        let d = BreathDetector()
        let est = sim.run(d, seconds: 90, bpm: 12)
        if let bpm = est.bpm { #expect(abs(bpm - 12) <= 1.0, "got \(bpm)") } else { Issue.record("no bpm") }
    }

    @Test("Inhale is the shorter half-cycle when no pacer hint is given")
    func phaseSign() {
        var sim = ChestSimulator()
        let d = BreathDetector()
        // run to a point known to be mid-inhale: phase in (0, 0.4) of the 5 s cycle
        _ = sim.run(d, seconds: 90, bpm: 12)
        // t = 90.0 is phase 0 → the next second is inhale (signal rising on +z)
        let est = sim.run(d, seconds: 1.0, bpm: 12, startTime: 90)
        #expect(est.phase == .inhale, "expected inhale during the rising part, got \(est.phase)")
    }
}

@Suite("Breath pattern envelope")
struct BreathPatternTests {

    @Test("Coherent swells to full at the end of the inhale and back to zero")
    func coherent() {
        let p = BreathPattern.coherent
        #expect(p.amplitude(at: 0) == 0)
        #expect(abs(p.amplitude(at: 5.45) - 1) < 1e-9)
        #expect(abs(p.amplitude(at: 10.9)) < 1e-9)
        #expect(abs(p.amplitude(at: 2.725) - 0.5) < 1e-9)
        #expect(abs(p.breathsPerMinute - 5.5) < 0.01)
    }

    @Test("Inhale amplitude is monotonic and eased, not linear")
    func eased() {
        let p = BreathPattern.coherent
        var prev = -1.0
        for i in 0...100 {
            let a = p.amplitude(at: 5.45 * Double(i) / 100)
            #expect(a >= prev)
            prev = a
        }
        // ease-in: quarter of the way in, well below a linear 0.25
        #expect(p.amplitude(at: 5.45 * 0.25) < 0.2)
    }

    @Test("Box holds at the hold level and rests at zero")
    func box() {
        let p = BreathPattern.box
        #expect(p.phase(at: 5).phase.kind == .holdIn)
        #expect(p.amplitude(at: 5) == 0.35)
        #expect(p.phase(at: 13).phase.kind == .holdOut)
        #expect(p.amplitude(at: 13) == 0)
        #expect(p.cycleSeconds == 16)
    }

    @Test("Time wraps around the cycle")
    func wraps() {
        let p = BreathPattern.fourSevenEight
        #expect(p.phase(at: 19 + 2).phase.kind == .inhale)
        #expect(abs(p.amplitude(at: 19 + 2) - p.amplitude(at: 2)) < 1e-9)
    }
}
