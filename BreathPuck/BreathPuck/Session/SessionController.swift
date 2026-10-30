import Foundation
import Observation

struct TracePoint: Identifiable {
    let id = UUID()
    let t: Double          // seconds since session start
    let level: Double      // detector output, g
    let amplitude: Double  // haptic envelope, 0...1
    let bpm: Double?
}

struct SessionSummary {
    let duration: Double
    let averageBpm: Double?
    let targetBpm: Double?
    let breathCount: Int
    let fractionInTarget: Double
    let fractionMoving: Double
}

/// Owns the detector, the chosen motion source, the pacing pattern and the haptic sinks.
/// Everything here runs on the main actor; sources hop onto it when they deliver samples.
@MainActor
@Observable
final class SessionController {
    enum SourceKind: String, CaseIterable, Identifiable {
        case phone = "iPhone on chest"
        case puck = "Breath Puck"
        var id: String { rawValue }
    }

    enum Mode: Hashable {
        case paced(BreathPattern)
        case follow          // haptic mirrors the detected breath
        case senseOnly
    }

    // configuration
    var sourceKind = SourceKind.phone
    var mode = Mode.paced(.coherent)
    var phoneHapticsEnabled = true
    var puckHapticsEnabled = true

    // live state
    private(set) var isRunning = false
    private(set) var estimate = BreathEstimate.empty
    private(set) var amplitude = 0.0
    private(set) var currentPhase: PhaseKind?
    private(set) var elapsed = 0.0
    private(set) var trace: [TracePoint] = []
    private(set) var summary: SessionSummary?
    private(set) var sourceName = ""

    // collaborators
    let puck = PuckBLE()
    @ObservationIgnored private let phoneSource = PhoneMotionSource()
    @ObservationIgnored private let phoneHaptics = PhoneHaptics()
    @ObservationIgnored private var detector = BreathDetector()
    @ObservationIgnored private var activeSource: MotionSource?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startUptime = 0.0
    @ObservationIgnored private var lastPhaseIndex = -1
    @ObservationIgnored private var tickUntil = 0.0
    @ObservationIgnored private var followRange = 0.01

    // statistics for the summary
    @ObservationIgnored private var bpmSamples: [Double] = []
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var inTargetTicks = 0
    @ObservationIgnored private var movingTicks = 0

    var wearPosition: WearPosition { WearPosition.guess(gravity: estimate.gravity) }

    var pattern: BreathPattern? {
        if case .paced(let p) = mode { return p }
        return nil
    }

    func start() {
        guard !isRunning else { return }
        detector = BreathDetector()
        trace.removeAll(keepingCapacity: true)
        summary = nil
        bpmSamples.removeAll(); tickCount = 0; inTargetTicks = 0; movingTicks = 0
        lastPhaseIndex = -1
        startUptime = ProcessInfo.processInfo.systemUptime
        elapsed = 0

        let source: MotionSource = sourceKind == .puck ? puck : phoneSource
        activeSource = source
        sourceName = source.name
        source.onSample = { [weak self] s in
            Task { @MainActor in self?.ingest(s) }
        }
        source.start()

        if phoneHapticsEnabled { phoneHaptics.startHaptics() }
        if puckHapticsEnabled { puck.startHaptics() }
        isRunning = true

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                await MainActor.run { self?.tick() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        ticker?.cancel(); ticker = nil
        activeSource?.stop()
        activeSource?.onSample = nil
        phoneHaptics.stopHaptics()
        puck.stopHaptics()
        isRunning = false
        amplitude = 0
        currentPhase = nil
        summary = SessionSummary(
            duration: elapsed,
            averageBpm: bpmSamples.isEmpty ? nil : bpmSamples.reduce(0, +) / Double(bpmSamples.count),
            targetBpm: pattern?.breathsPerMinute,
            breathCount: estimate.breathCount,
            fractionInTarget: tickCount == 0 ? 0 : Double(inTargetTicks) / Double(tickCount),
            fractionMoving: tickCount == 0 ? 0 : Double(movingTicks) / Double(tickCount))
    }

    private func ingest(_ s: AccelSample) {
        guard isRunning else { return }
        if let p = pattern {
            detector.externalPhaseHint = p.phase(at: elapsed).phase.kind.breathPhase
        } else {
            detector.externalPhaseHint = nil
        }
        estimate = detector.push(s)
    }

    private func tick() {
        guard isRunning else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - startUptime

        var amp = 0.0
        switch mode {
        case .paced(let p):
            let ph = p.phase(at: elapsed)
            currentPhase = ph.phase.kind
            amp = p.amplitude(at: elapsed)
            if p.tickOnPhaseChange, ph.index != lastPhaseIndex, lastPhaseIndex >= 0 {
                tickUntil = elapsed + 0.06
            }
            lastPhaseIndex = ph.index
            if elapsed < tickUntil { amp = max(amp, 0.8) }
        case .follow:
            currentPhase = nil
            // normalise the detector level into 0...1 with a slowly adapting range
            let mag = abs(estimate.level)
            followRange = max(0.002, followRange * 0.999, mag)
            amp = estimate.isMoving ? 0 : min(1, max(0, (estimate.level / followRange + 1) / 2))
        case .senseOnly:
            currentPhase = nil
            amp = 0
        }
        amplitude = amp
        if phoneHapticsEnabled { phoneHaptics.setAmplitude(amp) }
        if puckHapticsEnabled { puck.setAmplitude(amp) }

        // keep the last 30 s for the chart, sampled at 25 Hz by taking every other tick
        tickCount += 1
        if tickCount % 2 == 0 {
            trace.append(TracePoint(t: elapsed, level: estimate.level, amplitude: amp, bpm: estimate.bpm))
            if trace.count > 750 { trace.removeFirst(trace.count - 750) }
        }
        if let bpm = estimate.bpm {
            bpmSamples.append(bpm)
            if let target = pattern?.breathsPerMinute, abs(bpm - target) <= 1.5 { inTargetTicks += 1 }
        }
        if estimate.isMoving { movingTicks += 1 }
    }
}
