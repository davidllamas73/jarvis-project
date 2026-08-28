import Foundation
import AVFoundation

#if os(iOS)
import UIKit

/// Manages iOS audio session configuration and screen wake lock for voice conversations.
///
/// Key behaviors:
/// - Prevents screen from locking during active voice conversations
/// - Configures audio session for voice chat mode (speaker output, Bluetooth support)
/// - Ducks other app audio (music, etc.) during Jarvis speech
/// - Automatically restores normal behavior when conversation ends
///
/// Usage:
///   AudioSessionManager.shared.enableVoiceConversationMode()  // On query start
///   AudioSessionManager.shared.disableVoiceConversationMode() // On completion/error
@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published private(set) var isVoiceConversationActive = false

    private init() {}

    /// Enable voice conversation mode: prevents screen lock, configures audio for voice chat.
    ///
    /// This matches the behavior of WhatsApp voice messages, phone calls, and other
    /// messaging apps that need to keep the screen awake during audio playback and recording.
    ///
    /// Side effects:
    /// - Disables iOS idle timer (screen won't auto-lock)
    /// - Sets audio session to .voiceChat mode (optimized for voice conversations)
    /// - Routes audio to speaker (not earpiece) by default
    /// - Enables Bluetooth headset support
    /// - Ducks other app audio during playback
    func enableVoiceConversationMode() {
        guard !isVoiceConversationActive else {
            print("⚠️ AudioSessionManager: voice conversation mode already enabled")
            return
        }

        // Prevent screen from sleeping during conversation
        UIApplication.shared.isIdleTimerDisabled = true

        // Configure audio session for voice conversation
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord allows both mic input and speaker output
            // .voiceChat mode optimizes for voice conversation (echo cancellation, etc.)
            // .defaultToSpeaker routes audio to speaker, not earpiece (like speakerphone)
            // .allowBluetooth enables Bluetooth headset use
            // .duckOthers lowers other app audio (music, etc.) during Jarvis speech
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            isVoiceConversationActive = true
            print("✅ AudioSessionManager: voice conversation mode enabled (screen lock disabled)")
        } catch {
            print("❌ AudioSessionManager: failed to configure audio session: \(error)")
        }
    }

    /// Disable voice conversation mode: restore normal screen lock, deactivate audio session.
    ///
    /// Call this when the conversation ends (successfully or on error) to restore
    /// normal iOS behavior and allow the screen to auto-lock again.
    func disableVoiceConversationMode() {
        guard isVoiceConversationActive else {
            return
        }

        // Restore normal screen lock behavior
        UIApplication.shared.isIdleTimerDisabled = false

        let session = AVAudioSession.sharedInstance()
        do {
            // Deactivate session and notify other apps they can resume audio
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isVoiceConversationActive = false
            print("✅ AudioSessionManager: voice conversation mode disabled (screen lock restored)")
        } catch {
            print("❌ AudioSessionManager: failed to deactivate audio session: \(error)")
        }
    }

    /// Force-disable voice conversation mode even if currently active.
    /// Used when app backgrounds or encounters fatal error.
    func forceDisable() {
        if isVoiceConversationActive {
            print("⚠️ AudioSessionManager: force-disabling voice conversation mode")
            disableVoiceConversationMode()
        }
    }
}

#else

// macOS stub - screen lock prevention not needed on macOS
@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published private(set) var isVoiceConversationActive = false

    private init() {}

    func enableVoiceConversationMode() {
        // No-op on macOS
    }

    func disableVoiceConversationMode() {
        // No-op on macOS
    }

    func forceDisable() {
        // No-op on macOS
    }
}

#endif
