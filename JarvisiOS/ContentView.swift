import SwiftUI
import UniformTypeIdentifiers

/// iOS counterpart to the macOS ContentView. Same voice + text + attachment flow,
/// same shared Services/Models. The one real behavior difference: wake-word listening
/// here only runs while the app is in the foreground - iOS does not allow third-party
/// apps to keep the microphone open for a custom wake phrase while backgrounded/locked,
/// so "Hey Jarvis" only works with the app open and on screen.
struct ContentView: View {
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

    @State private var promptText = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                headerView

                Spacer()

                voiceInterfaceView

                promptInputView

                Spacer()

                if !currentResponse.isEmpty {
                    responseView
                }

                statusView
            }
            .padding()
            .task {
                await loadHealthStatus()
                setupWakeWord()
                wakeWordManager.startListening()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Foreground-only wake word: iOS won't let a third-party app keep
                // listening for a custom phrase once backgrounded or locked.
                switch newPhase {
                case .active:
                    wakeWordManager.startListening()
                case .background, .inactive:
                    wakeWordManager.stopListening()
                @unknown default:
                    break
                }
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
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Jarvis")
                .font(.system(size: 34, weight: .bold))

            if let chunks = chunksAvailable {
                Text("\(chunks) chunks available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                if apiClient.isAuthenticated {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Connected").font(.caption2).foregroundColor(.secondary)
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

            Text("Wake word only works while Jarvis is open")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    // MARK: - Voice Interface

    private var voiceInterfaceView: some View {
        VStack(spacing: 16) {
            Button(action: handleMicrophoneButtonTap) {
                ZStack {
                    Circle()
                        .fill(microphoneBackgroundColor)
                        .frame(width: 96, height: 96)
                        .shadow(color: microphoneBackgroundColor.opacity(0.3), radius: 10)

                    Image(systemName: microphoneIcon)
                        .font(.system(size: 38))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)

            if speechManager.isRecording {
                audioLevelView
            }

            if !speechManager.recognizedText.isEmpty && !isProcessing {
                transcriptionView
            }
        }
    }

    private var audioLevelView: some View {
        VStack(spacing: 8) {
            Text("Listening...").font(.caption).foregroundColor(.secondary)

            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: 6, height: waveformHeight(for: index))
                        .animation(.easeInOut(duration: 0.2), value: speechManager.audioLevel)
                }
            }

            Text(timeString(from: speechManager.recordingDuration))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    private var transcriptionView: some View {
        VStack(spacing: 4) {
            Text("You're saying:").font(.caption).foregroundColor(.secondary)
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

    // MARK: - Prompt Input

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

                TextField("Type a message to Jarvis...", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { submitPrompt() }

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
                        Image(systemName: "doc").font(.caption2)
                        Text(attachment.filename).font(.caption2).lineLimit(1)
                        Button(action: { removeAttachment(attachment) }) {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
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

    // MARK: - Response

    private var responseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jarvis:").font(.caption).foregroundColor(.secondary)
            Text(currentResponse)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 200, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .transition(.opacity)
    }

    // MARK: - Status

    private var statusView: some View {
        VStack(spacing: 4) {
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Processing...").font(.caption)
                }
            } else if ttsManager.isSpeaking {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").font(.caption)
                    Text("Playing response...").font(.caption)
                }
                .foregroundColor(.blue)
            } else {
                Text(speechManager.isRecording ? "Tap to stop" : "Tap microphone or type to talk to Jarvis")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Computed

    private var microphoneBackgroundColor: Color {
        if speechManager.isRecording { return .red }
        if isProcessing { return .orange }
        return .blue
    }

    private var microphoneIcon: String {
        if speechManager.isRecording { return "waveform.circle.fill" }
        if isProcessing { return "ellipsis.circle.fill" }
        return "mic.circle.fill"
    }

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

    private func loadHealthStatus() async {
        do {
            let health = try await apiClient.checkHealth()
            await MainActor.run { chunksAvailable = health.chromaChunks }
        } catch {
            print("⚠️ Could not load health status: \(error)")
        }
    }

    // MARK: - Wake Word

    private func setupWakeWord() {
        wakeWordManager.onWake = {
            guard !speechManager.isRecording, !isProcessing else { return }
            Task { await startVoiceInput() }
        }
        wakeWordManager.onSleep = {
            ttsManager.stop()
            if speechManager.isRecording {
                Task { await stopAndProcess() }
            }
        }
    }

    // MARK: - Voice Actions

    private func handleMicrophoneButtonTap() {
        if speechManager.isRecording {
            Task { await stopAndProcess() }
        } else {
            Task { await startVoiceInput() }
        }
    }

    private func startVoiceInput() async {
        do {
            wakeWordManager.suspendForActiveQuery()
            try await speechManager.startRecording()
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

            let transcribedText = try await speechManager.stopRecordingAndTranscribe()

            guard !transcribedText.isEmpty else {
                isProcessing = false
                wakeWordManager.resumeAfterActiveQuery()
                return
            }

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

    // MARK: - Text Prompt

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

    /// Streams the reply and speaks it sentence-by-sentence as it arrives, instead
    /// of waiting for the full answer - see the macOS ContentView for the same pattern.
    private func sendQuery(_ text: String, attachments: [PendingAttachment]) async throws {
        let apiAttachments = attachments.map {
            FileAttachment(filename: $0.filename, contentBase64: $0.base64Content)
        }

        let eventStream = apiClient.executeCodeStream(
            query: text,
            sessionId: sessionId,
            attachments: apiAttachments.isEmpty ? nil : apiAttachments
        )

        let (textChunks, textContinuation) = AsyncThrowingStream<String, Error>.makeStream()

        // Must clear BEFORE starting forwardingTask below, not after: Task{} schedules
        // immediately, so for a fast/short response the task can already be appending
        // deltas to currentResponse by the time this line would otherwise run - clearing
        // it afterward would wipe out a reply that already fully arrived (reproduced with
        // very short responses like "Hi!", which streamed and completed successfully per
        // the server logs but the "Jarvis:" box rendered empty on screen).
        await MainActor.run { currentResponse = "" }

        let forwardingTask = Task {
            do {
                for try await event in eventStream {
                    switch event {
                    case .textDelta(let delta):
                        await MainActor.run {
                            currentResponse += delta
                        }
                        textContinuation.yield(delta)
                    case .done(let response):
                        // Deltas are for incremental display/TTS pacing only - `answer` on
                        // `done` is the authoritative full text. If the server ever sends a
                        // `done` whose answer isn't fully covered by the deltas we saw (e.g.
                        // no deltas at all for a short reply), fall back to it so the box
                        // doesn't render empty despite a successful response.
                        await MainActor.run {
                            if currentResponse.isEmpty && !response.answer.isEmpty {
                                currentResponse = response.answer
                            }
                        }
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
        // Guarantees the forwarding task is cancelled on every exit path, including
        // speakStream() throwing - not just the normal-completion path.
        defer { forwardingTask.cancel() }

        try await ttsManager.speakStream(textChunks)

        isProcessing = false
    }

    // MARK: - File Attachments

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                do {
                    let data = try Data(contentsOf: url)
                    pendingAttachments.append(
                        PendingAttachment(filename: url.lastPathComponent, base64Content: data.base64EncodedString())
                    )
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
        errorMessage = message
        showError = true
        isProcessing = false
    }
}

#Preview {
    ContentView()
}
