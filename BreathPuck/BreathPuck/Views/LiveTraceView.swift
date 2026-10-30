import SwiftUI
import Charts

/// The detector's view of the world: filtered chest motion, the haptic envelope on top,
/// and the numbers that decide whether a breath is believed.
struct LiveTraceView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                metrics
                chart
                    .frame(height: 220)
                Text("Filtered chest motion in milli-g (blue) and haptic amplitude (teal). Lay the phone flat on your chest, breathe, and the blue line should swing once per breath. Walk and it should go flat with a “hold still” flag.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Live")
        }
    }

    private var metrics: some View {
        let e = session.estimate
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            Metric(title: "Rate", value: e.bpm.map { String(format: "%.1f", $0) } ?? "—", unit: "bpm")
            Metric(title: "Confidence", value: String(format: "%.0f", e.confidence * 100), unit: "%")
            Metric(title: "Breaths", value: "\(e.breathCount)", unit: "")
            Metric(title: "Phase", value: e.phase == .unknown ? "—" : e.phase.rawValue.capitalized, unit: "")
            Metric(title: "Moving", value: e.isMoving ? "yes" : "no", unit: "")
            Metric(title: "Position", value: session.wearPosition.rawValue, unit: "")
        }
    }

    private var chart: some View {
        Chart {
            ForEach(session.trace) { p in
                LineMark(x: .value("t", p.t), y: .value("level", p.level * 1000), series: .value("s", "motion"))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(session.trace) { p in
                LineMark(x: .value("t", p.t), y: .value("amp", (p.amplitude - 0.5) * 2 * yScale), series: .value("s", "haptic"))
                    .foregroundStyle(.teal.opacity(0.7))
            }
        }
        .chartYScale(domain: -yScale...yScale)
        .chartYAxisLabel("milli-g")
        .chartXAxis(.hidden)
    }

    /// A y-range that follows the recent signal so a quiet trace is not a flat line.
    private var yScale: Double {
        let m = session.trace.suffix(500).map { abs($0.level) * 1000 }.max() ?? 10
        return max(5, (m * 1.3).rounded(.up))
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    LiveTraceView().environment(SessionController())
}
