import Foundation

enum PhaseKind: String {
    case inhale, holdIn, exhale, holdOut

    var label: String {
        switch self {
        case .inhale: return "Inhale"
        case .holdIn: return "Hold"
        case .exhale: return "Exhale"
        case .holdOut: return "Rest"
        }
    }

    var breathPhase: BreathPhase {
        switch self {
        case .inhale, .holdIn: return .inhale
        case .exhale, .holdOut: return .exhale
        }
    }
}

struct PatternPhase: Hashable {
    let kind: PhaseKind
    let seconds: Double
}

/// A paced breathing pattern and the haptic amplitude it produces over time.
///
/// Inhale swells from 0 to 1, exhale fades from 1 to 0, both on an ease-in-out
/// curve. Holds sit at `holdLevel` (hold-in) or silence (rest). A linear ramp
/// feels mechanical; the smoothstep does not.
struct BreathPattern: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let phases: [PatternPhase]
    let holdLevel: Double
    let tickOnPhaseChange: Bool

    var cycleSeconds: Double { phases.reduce(0) { $0 + $1.seconds } }
    var breathsPerMinute: Double { 60 / cycleSeconds }

    /// Which phase is active at `t` seconds into the session, and how far through it we are (0...1).
    func phase(at t: Double) -> (index: Int, phase: PatternPhase, progress: Double) {
        let cycle = cycleSeconds
        var u = t.truncatingRemainder(dividingBy: cycle)
        if u < 0 { u += cycle }
        for (i, p) in phases.enumerated() {
            if u < p.seconds || i == phases.count - 1 {
                return (i, p, min(1, max(0, u / p.seconds)))
            }
            u -= p.seconds
        }
        return (0, phases[0], 0)
    }

    func amplitude(at t: Double) -> Double {
        let (_, p, u) = phase(at: t)
        switch p.kind {
        case .inhale: return smoothstep(u)
        case .exhale: return 1 - smoothstep(u)
        case .holdIn: return holdLevel
        case .holdOut: return 0
        }
    }

    static let coherent = BreathPattern(
        id: "coherent", name: "Coherent", detail: "5.5 breaths per minute, equal in and out",
        phases: [PatternPhase(kind: .inhale, seconds: 5.45), PatternPhase(kind: .exhale, seconds: 5.45)],
        holdLevel: 0, tickOnPhaseChange: false)

    static let box = BreathPattern(
        id: "box", name: "Box 4-4-4-4", detail: "In, hold, out, rest. Four seconds each.",
        phases: [PatternPhase(kind: .inhale, seconds: 4), PatternPhase(kind: .holdIn, seconds: 4),
                 PatternPhase(kind: .exhale, seconds: 4), PatternPhase(kind: .holdOut, seconds: 4)],
        holdLevel: 0.35, tickOnPhaseChange: true)

    static let fourSevenEight = BreathPattern(
        id: "478", name: "4-7-8", detail: "Short in, long hold, long out. Wind-down for sleep.",
        phases: [PatternPhase(kind: .inhale, seconds: 4), PatternPhase(kind: .holdIn, seconds: 7),
                 PatternPhase(kind: .exhale, seconds: 8)],
        holdLevel: 0.3, tickOnPhaseChange: true)

    static let all: [BreathPattern] = [coherent, box, fourSevenEight]
}

/// Ease-in-out, 0...1 → 0...1.
func smoothstep(_ u: Double) -> Double {
    let x = min(1, max(0, u))
    return x * x * (3 - 2 * x)
}
