import Foundation
import Combine
import SwiftUI

/// Drives voice mode on top of the existing services (SpeechRecognitionManagerSimple,
/// WakeWordManager, NativeTTSManager via ChatStore). Voice turns go through
/// ChatStore.send, so they land in the same transcript as typed turns.
///
/// Loop: listening → (tap) transcribing → thinking → speaking → listening ...
/// Tap the orb while Jarvis talks to interrupt. Say "thank you Jarvis" or tap End to leave.
@MainActor
final class VoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isPresented = false
    @Published private(set) var lastHeard = ""

    let speech = SpeechRecognitionManagerSimple()
    let wakeWord = WakeWordManager()

    private weak var store: ChatStore?
    private let audioSession = AudioSessionManager.shared
    private var currentMessageID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var wakeWordSuspended = false

    private let sleepPhrases = ["thank you jarvis", "thanks jarvis", "bye jarvis", "goodbye jarvis"]

    init(store: ChatStore) {
        self.store = store

        store.onSpeechFinished = { [weak self] id in
            self?.speechFinished(id)
        }
        wakeWord.onWake = { [weak self] in
            self?.wakeTriggered()
        }
        wakeWord.onSleep = { [weak self] in
            self?.end()
        }

        // Re-publish recorder level changes so the orb animates.
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        store.tts.$isSpeaking
            .removeDuplicates()
            .sink { [weak self] speaking in
                guard let self, speaking, self.phase == .thinking else { return }
                self.phase = .speaking
            }
            .store(in: &cancellables)

        store.$generatingMessageID
            .removeDuplicates()
            .sink { [weak self] id in
                guard id == nil else { return }
                // Defer one tick so ChatStore has finished updating message status.
                Task { @MainActor in self?.generationEnded() }
            }
            .store(in: &cancellables)
    }

    var audioLevel: Float { speech.audioLevel }

    private var autoSpeak: Bool {
        UserDefaults.standard.object(forKey: "autoSpeakVoice") as? Bool ?? true
    }

    private var wakeWordEnabled: Bool {
        UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? true
    }

    // MARK: - Wake word

    func startWakeWord() {
        guard wakeWordEnabled, !isPresented else { return }
        wakeWord.startListening()
    }

    func stopWakeWord() {
        wakeWord.stopListening()
    }

    private func wakeTriggered() {
        if !isPresented {
            open()
        } else if phase == .speaking || phase == .thinking {
            interrupt()
        }
    }

    // MARK: - Voice mode lifecycle

    func open() {
        isPresented = true
        if wakeWordEnabled {
            wakeWord.suspendForActiveQuery()
            wakeWordSuspended = true
        }
        audioSession.enableVoiceConversationMode()
        Task { await startListening() }
    }

    func end() {
        if speech.isRecording {
            Task { _ = try? await speech.stopRecordingAndTranscribe() }
        }
        store?.stopSpeaking()
        currentMessageID = nil
        phase = .idle
        isPresented = false
        audioSession.disableVoiceConversationMode()

        // isAwake latches true after "Hey Jarvis"; reset so the next wake phrase fires again.
        wakeWord.isAwake = false
        if wakeWordSuspended {
            wakeWordSuspended = false
            if wakeWordEnabled { wakeWord.resumeAfterActiveQuery() }
        }
    }

    /// The single orb tap: send while listening, interrupt while busy, retry on error.
    func primaryAction() {
        switch phase {
        case .listening:
            Task { await finishListening() }
        case .thinking, .speaking:
            interrupt()
        case .idle, .error:
            Task { await startListening() }
        case .transcribing:
            break
        }
    }

    /// Stop Jarvis talking and hand the mic back to the user. The text answer keeps
    /// streaming into the transcript.
    func interrupt() {
        store?.stopSpeaking()
        Task { await startListening() }
    }

    // MARK: - Turn steps

    private func startListening() async {
        guard isPresented, !speech.isRecording else { return }
        store?.stopSpeaking()
        do {
            try await speech.startRecording()
            phase = .listening
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "Couldn't start the microphone.")
        }
    }

    private func finishListening() async {
        guard phase == .listening else { return }
        phase = .transcribing
        do {
            let text = try await speech.stopRecordingAndTranscribe()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .error("I didn't catch that. Tap to try again.")
                return
            }
            lastHeard = text

            if sleepPhrases.contains(where: { text.lowercased().contains($0) }) {
                end()
                return
            }

            phase = .thinking
            currentMessageID = store?.send(text, speak: autoSpeak, viaVoice: true)
        } catch {
            phase = .error("I didn't catch that. Tap to try again.")
        }
    }

    private func speechFinished(_ id: UUID) {
        guard isPresented, id == currentMessageID else { return }
        Task { await startListening() }
    }

    private func generationEnded() {
        guard isPresented, phase == .thinking || phase == .speaking,
              let id = currentMessageID, let store,
              store.generatingMessageID == nil else { return }

        if let msg = store.message(id), msg.status == .failed {
            phase = .error(msg.errorText ?? "Something went wrong. Tap to try again.")
            return
        }
        // Not speaking (auto-speak off, or nothing to say): go straight back to listening.
        if !store.isSpeaking {
            Task { await startListening() }
        }
    }

    // MARK: - Display

    var statusText: String {
        switch phase {
        case .idle: return "Tap to talk"
        case .listening: return "Listening · tap when you're done"
        case .transcribing: return "Got it…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking · tap to interrupt"
        case .error(let message): return message
        }
    }
}
