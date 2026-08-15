import Foundation
import Speech
import AVFoundation
import Combine

/// Speech Recognition Manager using Apple's native Speech framework
/// Much faster and more reliable than recording + Whisper API
class SpeechRecognitionManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var recognizedText: String = ""
    @Published var audioLevel: Float = 0.0
    @Published var listeningDuration: TimeInterval = 0.0

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var listeningTimer: Timer?
    private var listeningStartTime: Date?

    override init() {
        // Initialize with user's preferred language (defaults to device language)
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()

        // Check if speech recognition is available
        guard speechRecognizer != nil else {
            print("❌ SpeechRecognitionManager: Speech recognition not available for this locale")
            return
        }

        speechRecognizer?.delegate = self
        print("✅ SpeechRecognitionManager: Initialized with locale: \(speechRecognizer?.locale.identifier ?? "unknown")")
    }

    // MARK: - Speech Recognition

    /// Start listening and recognizing speech in real-time
    func startListening() async throws -> String {
        print("🎤 SpeechRecognitionManager: Starting speech recognition...")

        // Request authorization
        let authorized = await requestAuthorization()
        guard authorized else {
            print("❌ SpeechRecognitionManager: Speech recognition not authorized")
            throw SpeechError.notAuthorized
        }

        // Check availability
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ SpeechRecognitionManager: Speech recognizer not available")
            throw SpeechError.notAvailable
        }

        // Configure audio session
        try configureAudioSession()

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechError.recognitionFailed
        }

        // Configure request for best results
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false // Use server for better accuracy

        // Get audio input node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        print("🔧 Audio format: \(recordingFormat.sampleRate) Hz, \(recordingFormat.channelCount) channels")

        // Install tap on audio engine
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            // Calculate audio level for visual feedback
            self?.updateAudioLevel(from: buffer)
        }

        // Prepare and start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        print("✅ SpeechRecognitionManager: Audio engine started")

        // Start recognition task
        return try await withCheckedThrowingContinuation { continuation in
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                var isFinal = false

                if let result = result {
                    let transcription = result.bestTranscription.formattedString

                    // Update recognized text in real-time
                    DispatchQueue.main.async {
                        self.recognizedText = transcription
                    }

                    isFinal = result.isFinal

                    if isFinal {
                        print("✅ Final transcription: '\(transcription)'")
                    } else {
                        print("📝 Partial: '\(transcription)'")
                    }
                }

                if let error = error {
                    print("❌ Recognition error: \(error.localizedDescription)")
                    self.stopListening()
                    continuation.resume(throwing: SpeechError.recognitionFailed)
                    return
                }

                if isFinal {
                    self.stopListening()
                    continuation.resume(returning: result?.bestTranscription.formattedString ?? "")
                }
            }

            DispatchQueue.main.async {
                self.isListening = true
                self.listeningStartTime = Date()
                self.startDurationTimer()
            }
        }
    }

    /// Stop listening and return the final recognized text
    func stopListening() {
        print("🛑 SpeechRecognitionManager: Stopping speech recognition...")

        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Stop timer
        stopDurationTimer()

        DispatchQueue.main.async {
            self.isListening = false
            self.listeningDuration = 0.0
            self.audioLevel = 0.0
        }

        print("✅ SpeechRecognitionManager: Stopped")
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        print("✅ Audio session configured for iOS")
        #elseif os(macOS)
        // macOS doesn't require explicit audio session configuration
        print("✅ Audio session ready for macOS")
        #endif
    }

    // MARK: - Audio Level Monitoring

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(rms)

        // Normalize to 0-1 range for UI
        let normalized = max(0, min(1, (avgPower + 50) / 50))

        DispatchQueue.main.async {
            self.audioLevel = normalized
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        listeningTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.listeningStartTime else { return }

            let duration = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self.listeningDuration = duration
            }
        }
    }

    private func stopDurationTimer() {
        listeningTimer?.invalidate()
        listeningTimer = nil
        listeningStartTime = nil
    }

    // MARK: - Authorization

    private func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    print("✅ Speech recognition authorized")
                    continuation.resume(returning: true)
                case .denied:
                    print("❌ Speech recognition denied")
                    continuation.resume(returning: false)
                case .restricted:
                    print("❌ Speech recognition restricted")
                    continuation.resume(returning: false)
                case .notDetermined:
                    print("⚠️ Speech recognition not determined")
                    continuation.resume(returning: false)
                @unknown default:
                    print("❌ Speech recognition unknown status")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Change Locale

    /// Change recognition language
    func changeLocale(to locale: Locale) {
        // Note: Would need to reinitialize with new locale
        print("💡 To change locale, reinitialize SpeechRecognitionManager with desired locale")
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechRecognitionManager: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available {
            print("✅ Speech recognizer became available")
        } else {
            print("⚠️ Speech recognizer became unavailable")
        }
    }
}

// MARK: - Errors

enum SpeechError: LocalizedError {
    case notAuthorized
    case notAvailable
    case recognitionFailed
    case audioEngineFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized. Please grant access in System Preferences > Security & Privacy > Speech Recognition."
        case .notAvailable:
            return "Speech recognition not available for this language"
        case .recognitionFailed:
            return "Speech recognition failed"
        case .audioEngineFailed:
            return "Audio engine failed to start"
        }
    }
}
