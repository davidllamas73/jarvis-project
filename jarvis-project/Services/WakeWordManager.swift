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
    let audioEngine = AVAudioEngine()  // Exposed for BargeInDetector integration
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Whether the query-capturing recognizer currently owns the mic.
    /// While true, the wake-word listener stays paused to avoid contention.
    private var isSuspended = false

    /// Mutex guard to prevent concurrent session transitions that would create
    /// CoreAudio HAL lock contention. Only one endSession()+beginSession() cycle
    /// may execute at a time; racing calls are no-opped rather than queued.
    private var isTransitioning = false

    /// Tracks consecutive session failures for exponential backoff. Reset to 0
    /// on any session that runs successfully for >5 seconds.
    private var consecutiveFailures = 0
    private var lastSessionStartTime: Date?

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

        do {
            try configureAudioSession()
        } catch {
            print("❌ WakeWordManager: audio session failed to configure: \(error)")
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // A zero-channel format means the audio session isn't actually active yet -
        // installTap with an invalid format crashes AVAudioEngine with an uncatchable
        // NSException rather than a throwable error, so this guard is load-bearing.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("❌ WakeWordManager: invalid input format (\(format)), aborting session")
            return
        }

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
        lastSessionStartTime = Date()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let heard = result.bestTranscription.formattedString.lowercased()
                self.evaluate(heard)
            }

            if let error {
                // Distinguish quota/rate-limit errors from benign session endings.
                // Per voice-conversation-protocol-design.md §5, quota errors need backoff.
                let errorString = error.localizedDescription.lowercased()
                let isQuotaError = errorString.contains("quota") || errorString.contains("rate limit")

                if isQuotaError {
                    print("⚠️ WakeWordManager: quota/rate-limit error, applying backoff")
                    Task { @MainActor in
                        self.consecutiveFailures += 1
                        await self.restartWithBackoff()
                    }
                } else {
                    print("⚠️ WakeWordManager: session error (non-quota), restarting: \(error)")
                    Task { @MainActor in
                        self.restartSessionIfNeeded()
                    }
                }
            } else if result?.isFinal ?? false {
                // Natural session end (silence/finality), not an error.
                // Reset failure counter if session ran for >5 seconds (healthy).
                if let startTime = self.lastSessionStartTime,
                   Date().timeIntervalSince(startTime) > 5 {
                    self.consecutiveFailures = 0
                }
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

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func restartSessionIfNeeded() {
        guard !isSuspended, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        endSession()
        beginSession()
    }

    /// Restart with exponential backoff based on consecutive failure count.
    /// Per voice-conversation-protocol-design.md §7.3: prevents quota-exhaustion
    /// feedback loops where errors trigger immediate retries that hit quota again.
    ///
    /// Claims isTransitioning for the entire backoff sleep, not just the eventual
    /// restart - otherwise a Timer- or error-driven restart landing mid-sleep would
    /// race ahead of the backoff and re-trigger the same failure immediately.
    private func restartWithBackoff() async {
        guard !isSuspended, !isTransitioning else { return }
        isTransitioning = true

        // Exponential backoff: 1s, 2s, 4s, 8s, capped at 10s
        let backoffSeconds = min(Double(1 << consecutiveFailures), 10.0)
        print("⏳ WakeWordManager: backing off \(backoffSeconds)s before retry (failure #\(consecutiveFailures))")

        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

        isTransitioning = false
        restartSessionIfNeeded()
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
