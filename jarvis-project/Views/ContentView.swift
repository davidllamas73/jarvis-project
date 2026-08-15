import SwiftUI

/// ContentView using Speech Recognition with YOUR actual services
/// This version uses JarvisAPIClient, AudioManager, and SpeechRecognitionManager
struct ContentView: View {
    // MARK: - State Management

    @StateObject private var speechManager = SpeechRecognitionManagerSimple()
    @StateObject private var ttsManager = NativeTTSManager()
    private let apiClient = JarvisAPIClient.shared

    @State private var sessionId = UUID().uuidString
    @State private var isProcessing = false
    @State private var currentResponse = ""
    @State private var chunksAvailable: Int?
    @State private var errorMessage: String?
    @State private var showError = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            // Header
            headerView

            Spacer()

            // Main Voice Interface
            voiceInterfaceView

            Spacer()

            // Response Display
            if !currentResponse.isEmpty {
                responseView
            }

            // Status
            statusView
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
        .task {
            await loadHealthStatus()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
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
                Text(speechManager.isRecording ? "Tap to stop" : "Tap microphone to speak")
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

    // MARK: - Actions

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

            // Start recording (doesn't set isProcessing yet)
            try await speechManager.startRecording()

            print("✅ Recording started - speak now!")

        } catch let error as SpeechError {
            await handleError(error.localizedDescription ?? "Failed to start recording")
        } catch {
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
                return
            }

            print("✅ Recognized: '\(transcribedText)'")

            // Send query to Jarvis API
            print("📤 Sending to Jarvis: '\(transcribedText)'")
            let codeResponse = try await apiClient.executeCode(
                query: transcribedText,
                sessionId: sessionId
            )

            await MainActor.run {
                currentResponse = codeResponse.answer
            }

            // Speak response using native TTS (instant, no API call)
            print("🔊 Speaking response with native TTS...")
            await ttsManager.speak(codeResponse.answer)

            print("✅ Voice workflow complete!")
            
            isProcessing = false

        } catch let error as SpeechError {
            await handleError(error.localizedDescription ?? "Speech recognition failed")
        } catch let error as APIError {
            await handleError(error.localizedDescription ?? "API error")
        } catch {
            await handleError("Voice input error: \(error.localizedDescription)")
        }
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

