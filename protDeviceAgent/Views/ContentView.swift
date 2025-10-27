

import SwiftUI
import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var runtime: AgentRuntime
    @EnvironmentObject var llm: LLMInference
    @State private var showPlanConfirm: Bool = false
    @State private var confirmTitle: String = ""
    @State private var confirmMessage: String = ""

    init() {}

    @State private var prompt: String = ""
    @State private var selectedImages: [Data] = []

    @State private var showingPhotoPicker: Bool = false
    @State private var photoSelection: PhotosPickerItem?

    var body: some View {
        TabView {
            VoiceInterface()
                .tabItem { Label("Voice", systemImage: "waveform") }
            ChatInterface()
                .tabItem { Label("Chat", systemImage: "message") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .onReceive(runtime.confirmer.$pendingQuestion) { pending in
            guard let p = pending else { return }
            confirmTitle = p.title
            confirmMessage = p.message
            showPlanConfirm = true
        }
        .alert(confirmTitle, isPresented: $showPlanConfirm) {
            Button("Cancel", role: .cancel) {
                runtime.confirmer.pendingQuestion?.cancel()
                runtime.confirmer.pendingQuestion = nil
            }
            Button("Approve", role: .none) {
                runtime.confirmer.pendingQuestion?.confirm()
                runtime.confirmer.pendingQuestion = nil
            }
        } message: {
            Text(confirmMessage)
        }
        // Removed auto download prompt at launch; warmup is triggered on demand by runtime
    }

    private func reset() {}
}

#Preview {
    ContentView()
}
