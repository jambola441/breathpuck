import Foundation
import CoreHaptics

/// Plays the breath envelope on the phone's Taptic Engine so the swell can be felt
/// and tuned before the puck exists. One long continuous event whose intensity is
/// steered at 50 Hz through a dynamic parameter.
final class PhoneHaptics: HapticSink {
    let name = "iPhone haptics"
    private(set) var isReady = false

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var running = false

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            try prepare()
        } catch {
            isReady = false
        }
    }

    private func prepare() throws {
        let e = try CHHapticEngine()
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = false
        e.resetHandler = { [weak self] in
            guard let self else { return }
            try? self.engine?.start()
            try? self.makePlayer()
            if self.running { self.startHaptics() }
        }
        e.stoppedHandler = { [weak self] _ in self?.isReady = false }
        try e.start()
        engine = e
        try makePlayer()
        isReady = true
    }

    private func makePlayer() throws {
        guard let engine else { return }
        // Intensity 1 here; the dynamic intensityControl multiplies it, so the envelope
        // drives the real level. Low sharpness reads as a soft hum rather than a click.
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)],
                                  relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let p = try engine.makeAdvancedPlayer(with: pattern)
        p.loopEnabled = true
        player = p
    }

    func startHaptics() {
        running = true
        try? engine?.start()
        setAmplitude(0)
        try? player?.start(atTime: CHHapticTimeImmediate)
    }

    func stopHaptics() {
        running = false
        try? player?.stop(atTime: CHHapticTimeImmediate)
    }

    func setAmplitude(_ amplitude: Double) {
        guard let player else { return }
        let v = Float(max(0, min(1, amplitude)))
        let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)
        try? player.sendParameters([p], atTime: CHHapticTimeImmediate)
    }
}
