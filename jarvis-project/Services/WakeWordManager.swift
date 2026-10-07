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
    /// Human-readable state for the Settings screen, so it's visible on device
    /// whether the listener is actually running or why it isn't.
    @Published private(set) var statusMessage = "Not started"

    /// Called when the wake phrase is heard.
    var onWake: (() -> Void)?
    /// Called when a sleep phrase is heard.
    var onSleep: (() -> Void)?

    private let wakePhrases = ["hey jarvis", "hi jarvis", "okay jarvis", "ok jarvis"]
    private let sleepPhrases = ["thank you jarvis", "thanks jarvis", "bye jarvis", "goodbye jarvis"]

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    let audioEngine = AVAudioEngine()  // Exposed for BargeInDetector integration
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Whether the query-capturing recognizer currently owns the mic.
    /// While true, the wake-word listener stays paused to avoid contention.
    private var isSuspended = false

    /// True while startListening() is awaiting authorization. Without it, the
    /// app-launch .task and the scenePhase .active handler both start a session
    /// and their failure retries run as two parallel loops.
    private var isStarting = false

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
        guard !isListeningForWakeWord, !isSuspended, !isStarting else { return }
        isStarting = true

        Task {
            let authorized = await requestAuthorization()
            isStarting = false
            guard authorized else {
                print("❌ WakeWordManager: not authorized")
                statusMessage = "Microphone or speech permission denied"
                return
            }
            guard !isSuspended, !isListeningForWakeWord else { return }
            beginSession()
        }
    }

    func stopListening() {
        restartTimer?.invalidate()
        restartTimer = nil
        endSession()
        isListeningForWakeWord = false
        statusMessage = "Stopped"
    }

    /// Pause wake-word listening while the app records/transcribes an actual query,
    /// so the two recognizers never fight over the microphone. Resumes automatically.
    func suspendForActiveQuery() {
        isSuspended = true
        endSession()
        isListeningForWakeWord = false
        statusMessage = "Paused while you talk"
    }

    func resumeAfterActiveQuery() {
        isSuspended = false
        startListening()
    }

    // MARK: - Session management

    private func beginSession() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ WakeWordManager: recognizer unavailable")
            statusMessage = "Speech recognizer unavailable"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep wake-word audio on-device when the phone has the en-US model.
        // Forcing it on a device WITHOUT the model makes every session fail
        // instantly, so the listener restarts forever and never hears anything.
        let onDevice = speechRecognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        if !onDevice {
            print("⚠️ WakeWordManager: no on-device en-US model, using server recognition")
        }
        recognitionRequest = request

        do {
            try configureAudioSession()
        } catch {
            // Real-device hazard: activating AVAudioSession can transiently fail
            // (e.g. right after app launch, before the hardware route settles).
            // Retrying with backoff rather than giving up permanently, so a
            // one-off failure doesn't disable wake-word for the rest of the
            // session. Not routed through restartWithBackoff() - beginSession()
            // can be called while isTransitioning is already held by
            // restartSessionIfNeeded() further up the call stack, and that
            // guard would silently no-op the retry in that case.
            print("❌ WakeWordManager: audio session failed to configure: \(error)")
            statusMessage = "Mic unavailable, retrying (\((error as NSError).code))"
            consecutiveFailures += 1
            // Cap the shift amount itself, not just the final result - 1 << N
        // overflows Int once consecutiveFailures climbs past ~62 (a real
        // scenario when a failure is persistent, not transient, and keeps
        // incrementing this every retry), crashing with a fatal trap when the
        // negative overflowed value is then force-converted to UInt64 below.
        let backoffSeconds = min(Double(1 << min(consecutiveFailures, 10)), 10.0)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                guard let self, !self.isSuspended else { return }
                self.startListening()
            }
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // A zero-channel format means the audio session isn't actually active yet -
        // installTap with an invalid format crashes AVAudioEngine with an uncatchable
        // NSException rather than a throwable error, so this guard is load-bearing.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            print("❌ WakeWordManager: invalid input format (\(inputFormat)), aborting session")
            return
        }

        // Append buffers in the mic's native format. SFSpeechAudioBufferRecognitionRequest
        // accepts any PCM format, so no resampling is needed. The previous 16kHz
        // AVAudioConverter fed the SAME buffer back on every input-block call
        // (always .haveData), duplicating audio and garbling it - on iPhone (48kHz
        // mic) that path ran for every buffer, so "Hey Jarvis" was never recognized.
        // Tapping with inputFormat (not a fixed format) is what fixed the original
        // "format mismatch" crash and is kept.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("❌ WakeWordManager: audio engine failed to start: \(error)")
            return
        }

        isListeningForWakeWord = true
        statusMessage = onDevice ? "Listening (on-device)" : "Listening (Apple servers)"
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
        // .measurement mode disables the system's usual audio processing and is
        // stricter about session priority than .default - on a real device this
        // was failing every activation attempt with OSStatus 561015905 ("!pla",
        // a category/priority conflict), not just transiently at launch as
        // first suspected. Wake-word detection doesn't need measurement-grade
        // signal precision, just clean speech audio for SFSpeechRecognizer, so
        // .default is both sufficient and markedly less prone to this failure.
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
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
        // Cap the shift amount itself, not just the final result - 1 << N
        // overflows Int once consecutiveFailures climbs past ~62 (a real
        // scenario when a failure is persistent, not transient, and keeps
        // incrementing this every retry), crashing with a fatal trap when the
        // negative overflowed value is then force-converted to UInt64 below.
        let backoffSeconds = min(Double(1 << min(consecutiveFailures, 10)), 10.0)
        print("⏳ WakeWordManager: backing off \(backoffSeconds)s before retry (failure #\(consecutiveFailures))")

        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

        isTransitioning = false
        restartSessionIfNeeded()
    }

    // MARK: - Phrase matching

    private func evaluate(_ rawHeard: String) {
        // Normalize: the recognizer may return "Hey, Jarvis." - strip punctuation
        // and collapse whitespace so it still matches "hey jarvis".
        let heard = rawHeard
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
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
