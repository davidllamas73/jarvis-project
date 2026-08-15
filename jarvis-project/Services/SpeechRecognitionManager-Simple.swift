import Foundation
import Speech
import AVFoundation
import Combine

/// Simple Speech Recognition using file-based approach
/// Records audio to file, then transcribes - avoids AVAudioEngine issues
class SpeechRecognitionManagerSimple: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recognizedText: String = ""
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0

    private let speechRecognizer: SFSpeechRecognizer?
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var recordingStartTime: Date?
    private var recordingURL: URL?

    override init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()

        guard speechRecognizer != nil else {
            print("❌ Speech recognition not available")
            return
        }

        speechRecognizer?.delegate = self
        print("✅ SpeechRecognitionManager: Initialized (file-based approach)")
    }

    // MARK: - Recording & Recognition

    /// Start recording audio
    func startRecording() async throws {
        print("🎤 Starting audio recording...")

        // Request permissions
        let speechAuth = await requestSpeechAuthorization()
        let micAuth = await requestMicrophonePermission()

        guard speechAuth && micAuth else {
            print("❌ Permissions denied")
            throw SpeechError.notAuthorized
        }

        try configureAudioSession()

        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "jarvis_speech_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL

        print("📁 Recording to: \(fileURL.path)")

        // Configure recording settings (same as AudioManager)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true

            guard audioRecorder?.record() == true else {
                print("❌ Failed to start recording")
                throw SpeechError.audioEngineFailed
            }

            print("✅ Recording started")

            await MainActor.run {
                isRecording = true
                recordingStartTime = Date()
            }

            // Start monitoring
            startLevelMonitoring()
            startDurationTimer()

            // Debug audio levels
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let avg = recorder.averagePower(forChannel: 0)
                let peak = recorder.peakPower(forChannel: 0)
                print("🔊 Audio levels: avg=\(avg) dB, peak=\(peak) dB")

                if avg < -50 {
                    print("⚠️ WARNING: Audio very quiet - increase input volume!")
                }
            }

        } catch {
            print("❌ Recording error: \(error)")
            throw SpeechError.audioEngineFailed
        }
    }

    /// Stop recording and transcribe the file
    func stopRecordingAndTranscribe() async throws -> String {
        guard let recorder = audioRecorder, isRecording else {
            throw SpeechError.recognitionFailed
        }

        print("🛑 Stopping recording...")

        // Get final metrics
        recorder.updateMeters()
        let finalAvg = recorder.averagePower(forChannel: 0)
        let finalPeak = recorder.peakPower(forChannel: 0)

        recorder.stop()
        stopLevelMonitoring()
        stopDurationTimer()

        await MainActor.run {
            isRecording = false
            recordingDuration = 0.0
            audioLevel = 0.0
        }

        guard let fileURL = recordingURL else {
            throw SpeechError.recognitionFailed
        }

        // Check file exists and has content
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        print("📊 Recorded file: \(fileSize) bytes, avg=\(finalAvg) dB, peak=\(finalPeak) dB")

        if finalAvg < -40 {
            print("⚠️ Recording is very quiet - transcription may fail")
        }

        guard fileSize > 1000 else {
            print("❌ Recording file too small or empty")
            try? FileManager.default.removeItem(at: fileURL)
            throw SpeechError.recognitionFailed
        }

        // Transcribe the file
        print("📝 Transcribing audio file...")
        let transcription = try await transcribeAudioFile(url: fileURL)

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
        recordingURL = nil

        print("✅ Transcription complete: '\(transcription)'")

        await MainActor.run {
            recognizedText = transcription
        }

        return transcription
    }

    /// Transcribe an audio file using Speech Recognition
    private func transcribeAudioFile(url: URL) async throws -> String {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechError.notAvailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    print("❌ Transcription error: \(error.localizedDescription)")
                    continuation.resume(throwing: SpeechError.recognitionFailed)
                    return
                }

                if let result = result, result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    continuation.resume(returning: transcription)
                }
            }
        }
    }

    // MARK: - Audio Level Monitoring

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder else { return }

            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)

            // Convert -160 dB to 0 dB range to 0-1
            let normalized = max(0, min(1, (averagePower + 160) / 160))

            DispatchQueue.main.async {
                self.audioLevel = normalized
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func startDurationTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }

            let duration = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self.recordingDuration = duration
            }
        }
    }

    private func stopDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Authorization

    private func requestSpeechAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #elseif os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }
}

// MARK: - AVAudioRecorderDelegate

extension SpeechRecognitionManagerSimple: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("⚠️ Recording did not finish successfully")
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("❌ Recording encode error: \(error?.localizedDescription ?? "unknown")")
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechRecognitionManagerSimple: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        print(available ? "✅ Speech recognizer available" : "⚠️ Speech recognizer unavailable")
    }
}
