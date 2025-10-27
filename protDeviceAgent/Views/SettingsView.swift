import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var runtime: AgentRuntime
    @EnvironmentObject var llm: LLMInference

    var body: some View {
        Form {
            Section("Capabilities") {
                ForEach($runtime.capabilities) { $cap in
                    Toggle(isOn: $cap.enabled) {
                        VStack(alignment: .leading) {
                            Text(cap.name)
                            Text(cap.description).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            Section("Model Information") {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(llm.modelConfiguration.name)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    if llm.isReady {
                        Text("Ready")
                            .foregroundColor(.green)
                    } else if llm.isDownloading {
                        Text("Downloading…")
                            .foregroundColor(.orange)
                    } else if llm.isDownloaded {
                        Text("Downloaded")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Not downloaded")
                            .foregroundColor(.secondary)
                    }
                }
                if let progress = llm.downloadProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.fractionCompleted)
                        Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let error = llm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                HStack {
                    Button(
                        llm.isReady ? "Re-download" : (
                            llm.isDownloading ? "Downloading…" : (
                                llm.isDownloaded ? "Load" : "Download"
                            )
                        )
                    ) {
                        Task { await llm.warmup() }
                    }
                    .disabled(llm.isDownloading)
                }
            }
        }
    }
}



