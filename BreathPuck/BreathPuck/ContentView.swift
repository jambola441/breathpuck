import SwiftUI

struct ContentView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        TabView {
            Tab("Session", systemImage: "wind") { SessionView() }
            Tab("Live", systemImage: "waveform.path.ecg") { LiveTraceView() }
            Tab("Puck", systemImage: "circle.circle") { PuckView() }
        }
    }
}

#Preview {
    ContentView().environment(SessionController())
}
