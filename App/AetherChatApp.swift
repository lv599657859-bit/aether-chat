import SwiftUI

@main
struct AetherChatApp: App {
    @State private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .preferredColorScheme(nil)
                .task { await env.bootstrap() }
                .onChange(of: scenePhase) { _, newValue in
                    Task { await env.scenePhaseChanged(newValue) }
                }
        }
    }
}
