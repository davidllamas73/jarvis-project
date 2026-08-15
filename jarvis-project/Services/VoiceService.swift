import Foundation
import Combine

class VoiceService: ObservableObject {
    @Published var isProcessing = false
    @Published var currentStatus: String = "Ready"
    @Published var lastError: String?

    private let apiClient = JarvisAPIClient.shared
    private let audioManager = AudioManager()

    // MARK: - Voice Conversation Flow

    /// Complete voice interaction: record → transcribe → chat → synthesize → play
    func startVoiceConversation() async {
        do {
            // Clear previous error
            await MainActor.run {
                lastError = nil
                isProcessing = true
                currentStatus = "Listening..."
            }

            // Step 1: Record audio
            try await audioManager.startRecording()

            // Let user speak (you can add auto-stop detection or fixed duration)
            // For now, caller should manually stop recording
            // Auto-stop after 30 seconds max
            try await Task.sleep(nanoseconds: 30_000_000_000)

            await MainActor.run {
                currentStatus = "Processing speech..."
            }

            // Step 2: Stop recording and get audio
            let audioBase64 = try await audioManager.stopRecording()

            // Step 3: Transcribe
            await MainActor.run {
                currentStatus = "Understanding your question..."
            }

            let transcription = try await apiClient.transcribe(audioBase64: audioBase64)

            // Step 4: Get answer via chat
            await MainActor.run {
                currentStatus = "Thinking..."
            }

            let chatResponse = try await apiClient.chat(query: transcription.text)

            // Step 5: Synthesize response
            await MainActor.run {
                currentStatus = "Preparing response..."
            }

            let speechResponse = try await apiClient.synthesize(text: chatResponse.answer)

            // Step 6: Play audio
            await MainActor.run {
                currentStatus = "Speaking..."
            }

            try await audioManager.playAudio(base64: speechResponse.audioBase64)

            // Done
            await MainActor.run {
                currentStatus = "Ready"
                isProcessing = false
            }

        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                currentStatus = "Error: \(error.localizedDescription)"
                isProcessing = false
            }
        }
    }

    /// Manual control: start recording
    func startRecording() async throws {
        await MainActor.run {
            lastError = nil
            currentStatus = "Recording..."
        }

        try await audioManager.startRecording()
    }

    /// Manual control: stop recording and process
    func stopRecordingAndProcess() async throws -> String {
        await MainActor.run {
            currentStatus = "Processing..."
        }

        let audioBase64 = try await audioManager.stopRecording()

        // Transcribe
        let transcription = try await apiClient.transcribe(audioBase64: audioBase64)

        // Get answer
        let chatResponse = try await apiClient.chat(query: transcription.text)

        // Synthesize and play
        let speechResponse = try await apiClient.synthesize(text: chatResponse.answer)
        try await audioManager.playAudio(base64: speechResponse.audioBase64)

        await MainActor.run {
            currentStatus = "Ready"
        }

        return chatResponse.answer
    }

    /// Process a voice query (audio already recorded)
    func processVoiceQuery(audioBase64: String) async throws -> String {
        await MainActor.run {
            isProcessing = true
            currentStatus = "Transcribing..."
        }

        // Step 1: Transcribe
        let transcription = try await apiClient.transcribe(audioBase64: audioBase64)

        await MainActor.run {
            currentStatus = "Getting answer..."
        }

        // Step 2: Get answer
        let chatResponse = try await apiClient.chat(query: transcription.text)

        await MainActor.run {
            currentStatus = "Synthesizing speech..."
        }

        // Step 3: Synthesize
        let speechResponse = try await apiClient.synthesize(text: chatResponse.answer)

        await MainActor.run {
            currentStatus = "Playing response..."
        }

        // Step 4: Play
        try await audioManager.playAudio(base64: speechResponse.audioBase64)

        await MainActor.run {
            currentStatus = "Ready"
            isProcessing = false
        }

        return chatResponse.answer
    }

    /// Stop any ongoing audio
    func stopAudio() {
        audioManager.stopPlayback()

        Task { @MainActor in
            currentStatus = "Stopped"
            isProcessing = false
        }
    }

    /// Check if currently recording
    var isRecording: Bool {
        audioManager.isRecording
    }

    /// Check if currently playing audio
    var isPlaying: Bool {
        audioManager.isPlaying
    }

    /// Get current audio level (for visualization)
    var audioLevel: Float {
        audioManager.audioLevel
    }

    /// Get recording duration
    var recordingDuration: TimeInterval {
        audioManager.recordingDuration
    }
}
