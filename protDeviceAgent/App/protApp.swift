import SwiftUI

@main
struct ProtApp: App {
    @StateObject private var runtime = AgentRuntime()
    @StateObject private var logger = AppLogger()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .environmentObject(runtime.llm)
                .environmentObject(logger)
                .onAppear { runtime.logger = logger }
        }
    }
}



