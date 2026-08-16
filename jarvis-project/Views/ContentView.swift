import SwiftUI
import UniformTypeIdentifiers

/// ContentView using Speech Recognition with YOUR actual services
/// This version uses JarvisAPIClient, AudioManager, and SpeechRecognitionManager
struct ContentView: View {
    // MARK: - State Management

    @StateObject private var speechManager = SpeechRecognitionManagerSimple()
    @StateObject private var ttsManager = NativeTTSManager()
    @StateObject private var wakeWordManager = WakeWordManager()
    private let apiClient = JarvisAPIClient.shared

    @State private var sessionId = UUID().uuidString
    @State private var isProcessing = false
    @State private var currentResponse = ""
    @State private var chunksAvailable: Int?
    @State private var errorMessage: String?
    @State private var showError = false

    // Text prompt input
    @State private var promptText = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            // Header
            headerView

            Spacer()

            // Main Voice Interface
            voiceInterfaceView

            // Text Prompt Input
            promptInputView

            Spacer()

            // Response Display
            if !currentResponse.isEmpty {
                responseView
            }

            // Status
            statusView
        }
        .padding()
        .frame(minWidth: 420, minHeight: 560)
        .task {
            await loadHealthStatus()
            setupWakeWord()
            wakeWordManager.startListening()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Jarvis")
                .font(.system(size: 36, weight: .bold))

            if let chunks = chunksAvailable {
                Text("\(chunks) chunks available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                if apiClient.isAuthenticated {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(wakeWordManager.isAwake ? Color.blue : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(wakeWordManager.isAwake ? "Awake" : "Say \"Hey Jarvis\"")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Voice Interface View

    private var voiceInterfaceView: some View {
        VStack(spacing: 16) {
            // Microphone Button
            Button(action: handleMicrophoneButtonTap) {
                ZStack {
                    // Background Circle
                    Circle()
                        .fill(microphoneBackgroundColor)
                        .frame(width: 100, height: 100)
                        .shadow(color: microphoneBackgroundColor.opacity(0.3), radius: 10)

                    // Icon
                    Image(systemName: microphoneIcon)
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)

            // Audio Level Indicator
            if speechManager.isRecording {
                audioLevelView
            }

            // Recognized text (after transcription)
            if !speechManager.recognizedText.isEmpty && !isProcessing {
                transcriptionView
            }
        }
    }

    // MARK: - Audio Level View

    private var audioLevelView: some View {
        VStack(spacing: 8) {
            Text("Listening...")
                .font(.caption)
                .foregroundColor(.secondary)

            // Animated waveform
            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: 6, height: waveformHeight(for: index))
                        .animation(.easeInOut(duration: 0.2), value: speechManager.audioLevel)
                }
            }

            // Duration
            Text(timeString(from: speechManager.recordingDuration))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Transcription View

    private var transcriptionView: some View {
        VStack(spacing: 4) {
            Text("You're saying:")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(speechManager.recognizedText)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .transition(.opacity)
    }

    // MARK: - Prompt Input View

    private var promptInputView: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                attachmentChipsView
            }

            HStack(spacing: 8) {
                Button(action: { showFileImporter = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach a file")

                TextField("Type a message to Jarvis...", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit {
                        submitPrompt()
                    }

                Button(action: submitPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSubmitPrompt ? .blue : .secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitPrompt)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)
        }
    }

    private var attachmentChipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.caption2)
                        Text(attachment.filename)
                            .font(.caption2)
                            .lineLimit(1)
                        Button(action: { removeAttachment(attachment) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                }
            }
        }
    }

    private var canSubmitPrompt: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: - Response View

    private var responseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jarvis:")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                Text(currentResponse)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .transition(.opacity)
    }

    // MARK: - Status View

    private var statusView: some View {
        VStack(spacing: 4) {
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing...")
                        .font(.caption)
                }
            } else if ttsManager.isSpeaking {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                    Text("Playing response...")
                        .font(.caption)
                }
                .foregroundColor(.blue)
            } else {
                Text(speechManager.isRecording ? "Tap to stop" : "Tap microphone or type to talk to Jarvis")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Computed Properties

    private var microphoneBackgroundColor: Color {
        if speechManager.isRecording {
            return .red
        } else if isProcessing {
            return .orange
        } else {
            return .blue
        }
    }

    private var microphoneIcon: String {
        if speechManager.isRecording {
            return "waveform.circle.fill"
        } else if isProcessing {
            return "ellipsis.circle.fill"
        } else {
            return "mic.circle.fill"
        }
    }

    // MARK: - Helper Functions

    private func waveformHeight(for index: Int) -> CGFloat {
        let baseHeight: CGFloat = 10
        let maxHeight: CGFloat = 50
        let center = 3.0
        let distance = abs(Double(index) - center) / center
        let multiplier = (1 - distance) * Double(speechManager.audioLevel)
        return baseHeight + (maxHeight - baseHeight) * CGFloat(multiplier)
    }

    private func timeString(from interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Load Health Status

    private func loadHealthStatus() async {
        do {
            let health = try await apiClient.checkHealth()
            await MainActor.run {
                chunksAvailable = health.chromaChunks
            }
        } catch {
            print("⚠️ Could not load health status: \(error)")
        }
    }

    // MARK: - Wake Word

    private func setupWakeWord() {
        wakeWordManager.onWake = {
            print("👋 Waking up - listening for your question")
            guard !speechManager.isRecording, !isProcessing else { return }
            Task {
                await startVoiceInput()
            }
        }
        wakeWordManager.onSleep = {
            print("😴 Going back to sleep")
            ttsManager.stop()
            if speechManager.isRecording {
                Task {
                    await stopAndProcess()
                }
            }
        }
    }

    // MARK: - Voice Actions

    private func handleMicrophoneButtonTap() {
        if speechManager.isRecording {
            // Stop recording and process
            Task {
                await stopAndProcess()
            }
        } else {
            // Start recording
            Task {
                await startVoiceInput()
            }
        }
    }

    private func startVoiceInput() async {
        do {
            print("🎤 Starting voice recording...")

            // Wake-word listener and query recognizer share one mic - hand it off cleanly
            wakeWordManager.suspendForActiveQuery()

            // Start recording (doesn't set isProcessing yet)
            try await speechManager.startRecording()

            print("✅ Recording started - speak now!")

        } catch let error as SpeechError {
            wakeWordManager.resumeAfterActiveQuery()
            await handleError(error.localizedDescription ?? "Failed to start recording")
        } catch {
            wakeWordManager.resumeAfterActiveQuery()
            await handleError("Recording error: \(error.localizedDescription)")
        }
    }

    private func stopAndProcess() async {
        do {
            isProcessing = true
            currentResponse = ""

            print("🛑 Stopping recording and transcribing...")

            // Stop recording and transcribe
            let transcribedText = try await speechManager.stopRecordingAndTranscribe()

            guard !transcribedText.isEmpty else {
                print("⚠️ No speech detected")
                isProcessing = false
                wakeWordManager.resumeAfterActiveQuery()
                return
            }

            print("✅ Recognized: '\(transcribedText)'")

            try await sendQuery(transcribedText, attachments: [])

            wakeWordManager.resumeAfterActiveQuery()

        } catch let error as SpeechError {
            wakeWordManager.resumeAfterActiveQuery()
            await handleError(error.localizedDescription ?? "Speech recognition failed")
        } catch let error as APIError {
            wakeWordManager.resumeAfterActiveQuery()
            await handleError(error.localizedDescription ?? "API error")
        } catch {
            wakeWordManager.resumeAfterActiveQuery()
            await handleError("Voice input error: \(error.localizedDescription)")
        }
    }

    // MARK: - Text Prompt Actions

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing else { return }

        let attachments = pendingAttachments
        promptText = ""
        pendingAttachments = []

        Task {
            do {
                isProcessing = true
                currentResponse = ""
                try await sendQuery(text, attachments: attachments)
            } catch let error as APIError {
                await handleError(error.localizedDescription ?? "API error")
            } catch {
                await handleError("Request error: \(error.localizedDescription)")
            }
        }
    }

    /// Shared path for both voice and text queries: stream the reply from Jarvis and
    /// speak it sentence-by-sentence as it arrives, instead of waiting for the full
    /// answer. This is what makes responses feel conversational instead of stilted.
    private func sendQuery(_ text: String, attachments: [PendingAttachment]) async throws {
        print("📤 Sending to Jarvis (streaming): '\(text)'")

        let apiAttachments = attachments.map {
            FileAttachment(filename: $0.filename, contentBase64: $0.base64Content)
        }

        let eventStream = apiClient.executeCodeStream(
            query: text,
            sessionId: sessionId,
            attachments: apiAttachments.isEmpty ? nil : apiAttachments
        )

        // Bridge StreamEvent -> plain text chunks for the TTS queue, while updating
        // the on-screen response live as each chunk arrives.
        let (textChunks, textContinuation) = AsyncThrowingStream<String, Error>.makeStream()

        let forwardingTask = Task {
            do {
                for try await event in eventStream {
                    switch event {
                    case .textDelta(let delta):
                        await MainActor.run {
                            currentResponse += delta
                        }
                        textContinuation.yield(delta)
                    case .done:
                        textContinuation.finish()
                    case .error(let message):
                        textContinuation.finish(throwing: APIError.serverError(message))
                    }
                }
                textContinuation.finish()
            } catch {
                textContinuation.finish(throwing: error)
            }
        }

        await MainActor.run {
            currentResponse = ""
        }

        print("🔊 Speaking response as it streams in...")
        try await ttsManager.speakStream(textChunks)
        forwardingTask.cancel()

        print("✅ Voice workflow complete!")

        isProcessing = false
    }

    // MARK: - File Attachments

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }

                do {
                    let data = try Data(contentsOf: url)
                    let attachment = PendingAttachment(
                        filename: url.lastPathComponent,
                        base64Content: data.base64EncodedString()
                    )
                    pendingAttachments.append(attachment)
                } catch {
                    print("❌ Failed to read attached file \(url.lastPathComponent): \(error)")
                }
            }
        case .failure(let error):
            print("❌ File import failed: \(error)")
        }
    }

    private func removeAttachment(_ attachment: PendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    @MainActor
    private func handleError(_ message: String) {
        print("❌ Error: \(message)")
        errorMessage = message
        showError = true
        isProcessing = false
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
