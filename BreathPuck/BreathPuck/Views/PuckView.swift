import SwiftUI
import CoreBluetooth

/// Connection state for the hardware puck. Until the puck exists this tab mostly
/// documents the Bluetooth contract the firmware must meet.
struct PuckView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        let puck = session.puck
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("State", value: puck.state.rawValue.capitalized)
                    if let b = puck.batteryPercent { LabeledContent("Battery", value: "\(b)%") }
                    if let r = puck.rssi { LabeledContent("Signal", value: "\(r) dBm") }
                    LabeledContent("Packets", value: "\(puck.packetsReceived) received, \(puck.packetsDropped) dropped")
                    if let err = puck.lastError {
                        Text(err).font(.footnote).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Connect") { puck.connect() }
                            .disabled(puck.state == .connected || puck.state == .scanning)
                        Spacer()
                        Button("Disconnect", role: .destructive) { puck.disconnect() }
                            .disabled(puck.state != .connected)
                    }
                }
                Section("Where is it clipped?") {
                    LabeledContent("Guess", value: session.wearPosition.rawValue)
                    LabeledContent("Mode", value: session.wearPosition.sensesBreath ? "Sense and pace" : "Pace only")
                    Text("From the gravity direction. Thresholds are placeholders until a real puck has been worn at the neckline, sleeve and hem.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Bluetooth contract (firmware must match)") {
                    contractRow("Service", PuckBLE.UUIDs.service.uuidString)
                    contractRow("IMU notify", PuckBLE.UUIDs.imu.uuidString + "\nint16 ax, ay, az at 8192 counts/g, uint16 seq. 25 Hz.")
                    contractRow("Haptic write", PuckBLE.UUIDs.haptic.uuidString + "\n1 byte amplitude 0…127, write without response, 50 Hz.")
                    contractRow("Battery", "Standard Battery Service 0x180F, level 0x2A19.")
                }
            }
            .navigationTitle("Puck")
        }
    }

    private func contractRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }
    }
}

#Preview {
    PuckView().environment(SessionController())
}
