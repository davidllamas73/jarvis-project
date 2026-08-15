import Foundation
import AVFoundation
import Combine

class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var recordingStartTime: Date?

    override init() {
        super.init()
        setupAudioSession()
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        #if os(iOS)
        // iOS: Configure audio session for recording
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            print("✅ AudioManager: Audio session configured for iOS recording")
        } catch {
            print("⚠️ AudioManager: Could not configure audio session: \(error)")
        }
        #elseif os(macOS)
        // macOS: Audio routing handled at system level
        print("ð§ AudioManager: Ready for macOS audio recording")
        #endif
    }
    
    // MARK: - Recording

    func startRecording() async throws {
        print("🎤 AudioManager: Starting recording...")
        
        // Request microphone permission
        let granted = await requestMicrophonePermission()
        guard granted else {
            print("❌ AudioManager: Microphone permission denied")
            throw AudioError.permissionDenied
        }
        print("✅ AudioManager: Microphone permission granted")

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "jarvis_recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)
        print("🗂️ AudioManager: Recording to \(fileURL.path)")

        // Configure recording settings optimized for speech
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,              // High quality sample rate
            AVNumberOfChannelsKey: 1,               // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000,           // 128 kbps for clear speech
            AVLinearPCMBitDepthKey: 16,            // 16-bit depth
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true

            guard audioRecorder?.record() == true else {
                print("❌ AudioManager: Failed to start recording")
                throw AudioError.recordingFailed
            }
            
            print("✅ AudioManager: Recording started successfully")

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStartTime = Date()
            }

            // Start monitoring audio levels
            startLevelMonitoring()
            startDurationTimer()

            // Debug: Check initial audio level after 0.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let avgPower = recorder.averagePower(forChannel: 0)
                let peakPower = recorder.peakPower(forChannel: 0)
                print("ℹ Initial audio levels: avg=\(avgPower) dB, peak=\(peakPower) dB")

                if avgPower < -50 {
                    print("⚠️ WARNING: Audio level is very low! Check microphone input volume.")
                }
            }

        } catch {
            print("❌ AudioManager: Recording error: \(error)")
            throw AudioError.recordingFailed
        }
    }

    func stopRecording() async throws -> String {
        guard let recorder = audioRecorder, isRecording else {
            throw AudioError.notRecording
        }

        // Get final audio metrics before stopping
        recorder.updateMeters()
        let finalAvgPower = recorder.averagePower(forChannel: 0)
        let finalPeakPower = recorder.peakPower(forChannel: 0)

        recorder.stop()
        stopLevelMonitoring()
        stopDurationTimer()

        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingDuration = 0.0
            self.audioLevel = 0.0
        }

        // Read audio file and convert to base64
        let url = recorder.url

        do {
            let audioData = try Data(contentsOf: url)
            let base64String = audioData.base64EncodedString()

            print("📊 Recording stats: size=\(audioData.count) bytes, avg=\(finalAvgPower) dB, peak=\(finalPeakPower) dB")

            if finalAvgPower < -40 {
                print("⚠️ WARNING: Recording is very quiet (avg \(finalAvgPower) dB). Whisper may fail.")
                print("💡 Suggestion: Increase microphone input volume in System Preferences > Sound > Input")
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: url)

            return base64String
        } catch {
            throw AudioError.encodingFailed
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder else { return }

            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)

            // Convert decibels to 0-1 range
            // -160 dB (silence) to 0 dB (max)
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

    // MARK: - Playback

    func playAudio(base64: String) async throws {
        // Decode base64 to data
        guard let audioData = Data(base64Encoded: base64) else {
            throw AudioError.decodingFailed
        }

        // Stop any existing playback
        stopPlayback()

        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            DispatchQueue.main.async {
                self.isPlaying = true
            }

            audioPlayer?.play()
        } catch {
            throw AudioError.playbackFailed
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil

        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        // macOS 10.14+ requires explicit microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return true
        #endif
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Recording error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("Playback error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}

// MARK: - Errors

enum AudioError: LocalizedError {
    case permissionDenied
    case recordingFailed
    case notRecording
    case fileNotFound
    case encodingFailed
    case decodingFailed
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Please grant access in System Preferences > Security & Privacy > Microphone."
        case .recordingFailed:
            return "Failed to start recording"
        case .notRecording:
            return "No active recording"
        case .fileNotFound:
            return "Recording file not found"
        case .encodingFailed:
            return "Failed to encode audio"
        case .decodingFailed:
            return "Failed to decode audio"
        case .playbackFailed:
            return "Failed to play audio"
        }
    }
}
