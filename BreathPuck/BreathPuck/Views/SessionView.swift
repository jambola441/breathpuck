import SwiftUI

/// Pick a pattern, start, watch the circle swell with the haptic, stop, read the summary.
struct SessionView: View {
    @Environment(SessionController.self) private var session
    @State private var selectedPattern = BreathPattern.coherent
    @State private var follow = false

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            VStack(spacing: 24) {
                if !session.isRunning {
                    controls(session: $session)
                }
                breathCircle
                statusLine
                Spacer(minLength: 0)
                if let s = session.summary, !session.isRunning {
                    SummaryCard(summary: s)
                }
                Button {
                    if session.isRunning { session.stop() } else {
                        session.mode = follow ? .follow : .paced(selectedPattern)
                        session.start()
                    }
                } label: {
                    Text(session.isRunning ? "Stop" : "Start")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isRunning ? .red : .accentColor)
            }
            .padding()
            .navigationTitle("Breath Puck")
        }
    }

    @ViewBuilder
    private func controls(session: Bindable<SessionController>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: session.sourceKind) {
                ForEach(SessionController.SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Follow my own breath instead of pacing", isOn: $follow)

            if !follow {
                Picker("Pattern", selection: $selectedPattern) {
                    ForEach(BreathPattern.all) { p in
                        Text(p.name).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text(selectedPattern.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Phone haptics", isOn: session.phoneHapticsEnabled)
                Toggle("Puck haptics", isOn: session.puckHapticsEnabled)
            }
            .font(.footnote)
        }
    }

    private var breathCircle: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .fill(Color.accentColor.opacity(0.18 + 0.5 * session.amplitude))
                .scaleEffect(0.45 + 0.55 * session.amplitude)
            Circle()
                .stroke(Color.accentColor, lineWidth: 3)
                .scaleEffect(0.45 + 0.55 * session.amplitude)
            VStack(spacing: 4) {
                Text(session.currentPhase?.label ?? (session.isRunning ? "Breathe" : "Ready"))
                    .font(.title2.weight(.medium))
                if session.isRunning {
                    Text(timeString(session.elapsed)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 260, maxHeight: 260)
        .animation(.linear(duration: 0.02), value: session.amplitude)
    }

    private var statusLine: some View {
        HStack(spacing: 18) {
            Label(session.estimate.bpm.map { String(format: "%.1f bpm", $0) } ?? "— bpm", systemImage: "lungs")
            Label(String(format: "%.0f%%", session.estimate.confidence * 100), systemImage: "checkmark.seal")
            if session.estimate.isMoving {
                Label("Hold still", systemImage: "figure.walk").foregroundStyle(.orange)
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func timeString(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

struct SummaryCard: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last session").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Duration"); Text(String(format: "%.0f s", summary.duration)) }
                GridRow { Text("Breaths counted"); Text("\(summary.breathCount)") }
                GridRow { Text("Average rate"); Text(summary.averageBpm.map { String(format: "%.1f bpm", $0) } ?? "—") }
                if let t = summary.targetBpm {
                    GridRow { Text("Target"); Text(String(format: "%.1f bpm", t)) }
                    GridRow { Text("Time in target"); Text(String(format: "%.0f%%", summary.fractionInTarget * 100)) }
                }
                GridRow { Text("Time moving"); Text(String(format: "%.0f%%", summary.fractionMoving * 100)) }
            }
            .font(.footnote.monospacedDigit())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    SessionView().environment(SessionController())
}
