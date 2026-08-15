import Foundation
import Speech
import AVFoundation
import Combine

/// Continuous on-device listener for wake/sleep phrases.
/// "Hey Jarvis" -> wakes the app (ready to take a query)
/// "Thank you, Jarvis" / "Bye, Jarvis" -> puts the app back to sleep
///
/// Runs a rolling on-device SFSpeechRecognizer session so it never sends
/// raw audio to a server just to catch the wake phrase. Restarts itself
/// periodically because SFSpeechRecognizer sessions time out on their own.
@MainActor
class WakeWordManager: NSObject, ObservableObject {
    @Published var isAwake = false
    @Published var isListeningForWakeWord = false

    /// Called when the wake phrase is heard.
    var onWake: (() -> Void)?
    /// Called when a sleep phrase is heard.
    var onSleep: (() -> Void)?

    private let wakePhrases = ["hey jarvis"]
    private let sleepPhrases = ["thank you jarvis", "thanks jarvis", "bye jarvis", "goodbye jarvis"]

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Whether the query-capturing recognizer currently owns the mic.
    /// While true, the wake-word listener stays paused to avoid contention.
    private var isSuspended = false

    private var restartTimer: Timer?

    // MARK: - Lifecycle

    /// Begin continuous background listening for wake/sleep phrases.
    func startListening() {
        guard !isListeningForWakeWord, !isSuspended else { return }

        Task {
            let authorized = await requestAuthorization()
            guard authorized else {
                print("❌ WakeWordManager: not authorized")
                return
            }
            beginSession()
        }
    }

    func stopListening() {
        restartTimer?.invalidate()
        restartTimer = nil
        endSession()
        isListeningForWakeWord = false
    }

    /// Pause wake-word listening while the app records/transcribes an actual query,
    /// so the two recognizers never fight over the microphone. Resumes automatically.
    func suspendForActiveQuery() {
        isSuspended = true
        endSession()
        isListeningForWakeWord = false
    }

    func resumeAfterActiveQuery() {
        isSuspended = false
        startListening()
    }

    // MARK: - Session management

    private func beginSession() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ WakeWordManager: recognizer unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // keep wake-word audio on-device
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("❌ WakeWordManager: audio engine failed to start: \(error)")
            return
        }

        isListeningForWakeWord = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let heard = result.bestTranscription.formattedString.lowercased()
                self.evaluate(heard)
            }

            if error != nil || (result?.isFinal ?? false) {
                // On-device sessions end after a short window of silence/finality.
                // Restart transparently so listening feels continuous.
                Task { @MainActor in
                    self.restartSessionIfNeeded()
                }
            }
        }

        // On-device SFSpeechRecognizer sessions cap out after ~1 minute;
        // proactively cycle the session so wake-word detection never silently stops.
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restartSessionIfNeeded()
            }
        }
    }

    private func endSession() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func restartSessionIfNeeded() {
        guard !isSuspended else { return }
        endSession()
        beginSession()
    }

    // MARK: - Phrase matching

    private func evaluate(_ heard: String) {
        if !isAwake, wakePhrases.contains(where: { heard.contains($0) }) {
            isAwake = true
            print("👋 Wake phrase detected")
            onWake?()
            restartSessionIfNeeded() // clear the transcript so the phrase isn't re-matched
            return
        }

        if isAwake, sleepPhrases.contains(where: { heard.contains($0) }) {
            isAwake = false
            print("😴 Sleep phrase detected")
            onSleep?()
            restartSessionIfNeeded()
            return
        }
    }

    // MARK: - Authorization

    private func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechStatus else { return false }

        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #else
        return true
        #endif
    }
}
