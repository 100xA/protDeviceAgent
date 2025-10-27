import SwiftUI

struct ChatInterface: View {
    @EnvironmentObject var runtime: AgentRuntime
    @State private var input: String = ""
    @State private var showMap: Bool = false
    @State private var mapLat: Double = 0
    @State private var mapLon: Double = 0

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                AgentStatusIndicator(state: runtime.state)
                if [.processing, .executing, .waitingForConfirmation, .awaitingClarification].contains(runtime.state) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("Ready")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 4)
            ScrollView {
                ForEach(Array(runtime.memory.recent(limit: 50).enumerated()), id: \.offset) { _, msg in
                    HStack {
                        switch msg {
                        case .user(let t): Text("You: \(t)")
                        case .assistant(let t): Text("AI: \(t)")
                        case .toolCall(let c): Text("Tool: \(c.name)")
                        case .toolResult(let r):
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Result: \(r.result)")
                                if let latS = r.artifacts?["latitude"], let lonS = r.artifacts?["longitude"],
                                   let lat = Double(latS), let lon = Double(lonS), r.success {
                                    Button("Show on Map") {
                                        mapLat = lat; mapLon = lon; showMap = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        case .system(let t): Text("System: \(t)")
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                TextField("Type a message", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { let text = input; input = ""; Task { await runtime.processInput(text) } }
            }
        }
        .padding()
        .sheet(isPresented: $showMap) {
            LocationMapView(latitude: mapLat, longitude: mapLon)
        }
        .alert(runtime.confirmer.pendingQuestion?.title ?? "", isPresented: Binding<Bool>(
            get: { runtime.confirmer.pendingQuestion != nil },
            set: { if !$0 { runtime.confirmer.pendingQuestion = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                runtime.confirmer.pendingQuestion?.cancel()
                runtime.confirmer.pendingQuestion = nil
            }
            Button("OK") {
                runtime.confirmer.pendingQuestion?.confirm()
                runtime.confirmer.pendingQuestion = nil
            }
        } message: {
            Text(runtime.confirmer.pendingQuestion?.message ?? "")
        }
    }
}



