import SwiftUI
import AVFoundation
import Speech

struct VoiceInterface: View {
    @EnvironmentObject var runtime: AgentRuntime
    @State private var transcript: String = ""
    @State private var isRecording: Bool = false
    @State private var speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    #if os(iOS)
    @State private var micAuthStatus: AVAudioSession.RecordPermission = .undetermined
    #endif
    private let recognizer = SpeechRecognizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.headline)
            TextEditor(text: $transcript)
                .frame(minHeight: 100)
            HStack {
                Button(action: toggleRecording) {
                    Label(isRecording ? "Stop" : "Record", systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .blue)
                Button("Process") { Task { await runtime.processInput(transcript) } }
                Spacer()
                AgentStatusIndicator(state: runtime.state)
            }
        }
        .padding()
        .onAppear {
            requestPermissions()
            recognizer.onTranscriptionUpdate = { text in
                DispatchQueue.main.async { transcript = text }
            }
            recognizer.onFinalTranscription = { text in
                DispatchQueue.main.async {
                    transcript = text
                    Task {
                        await runtime.processInput(text)
                        await MainActor.run { transcript = "" }
                    }
                }
            }
        }
    }
}

struct AgentStatusIndicator: View {
    let state: AgentState
    var color: Color {
        switch state {
        case .idle: return .green
        case .listening: return .blue
        case .processing: return .orange
        case .executing: return .purple
        case .waitingForConfirmation: return .yellow
        case .error: return .red
        @unknown default: return .gray
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}




final class SpeechRecognizer: NSObject {
    var onTranscriptionUpdate: ((String) -> Void)?
    var onFinalTranscription: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    func start() throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

         let inputNode = audioEngine.inputNode
        
        
        //else { throw NSError(domain: "audio", code: -1) }
        guard let request else { throw NSError(domain: "speech", code: -1) }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.onTranscriptionUpdate?(text)
                    if result.isFinal {
                        self.onFinalTranscription?(text)
                        self.stop()
                    }
                }
            } else if error != nil {
                Task { @MainActor in
                    self.stop()
                }
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }
}

private extension VoiceInterface {
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            speechAuthStatus = status
        }
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            micAuthStatus = granted ? .granted : .denied
        }
        #endif
    }

    func toggleRecording() {
        guard speechAuthStatus == .authorized, hasMicPermission() else { return }
        if isRecording {
            recognizer.stop()
            isRecording = false
        } else {
            do {
                try recognizer.start()
                transcript = ""
                isRecording = true
            } catch {
                isRecording = false
            }
        }
    }

    private func hasMicPermission() -> Bool {
        #if os(iOS)
        return micAuthStatus == .granted
        #else
        return true
        #endif
    }
}
