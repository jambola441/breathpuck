import SwiftUI

@main
struct BreathPuckApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
