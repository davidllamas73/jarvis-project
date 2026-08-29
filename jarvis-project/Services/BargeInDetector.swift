import Foundation
import AVFoundation
import Combine

/// Detects user interruption (barge-in) during TTS playback via Voice Activity Detection.
///
/// The barge-in problem: User should be able to interrupt Jarvis mid-response by speaking over it,
/// similar to interrupting Alexa/Siri. This requires detecting sustained speech input while TTS is active.
///
/// Design:
/// - Uses energy-based VAD (Voice Activity Detection) on live mic input
/// - Requires sustained voice activity (>250ms) to trigger interruption
/// - Filters false positives from coughs, background noise, or brief sounds
/// - <150ms detection latency requirement (measured from start of user speech to TTS stop)
///
/// Integration:
/// - Wire to AVAudioEngine's input tap (same buffer source as SFSpeechRecognizer)
/// - Monitor only when orchestrator.state == .speaking
/// - On barge-in detected: cancel TTS, transition to .listening, capture new query
///
/// False Positive Mitigation:
/// - 250ms minimum sustained speech (filters coughs, door slams)
/// - Energy threshold calibrated above ambient noise floor
/// - Only armed during TTS playback (not during processing)
///
/// References:
/// - EdgeAI on-device barge-in: https://www.runedge.ai/blog/barge-in-interruption-handling-on-device-voice
/// - FutureAGI turn-taking 2026: https://futureagi.com/blog/voice-ai-barge-in-turn-taking-2026/
@MainActor
class BargeInDetector: ObservableObject {

    // MARK: - Configuration

    /// Energy threshold for voice activity detection (calibrated for typical mic levels)
    /// Values: 0.0 (silence) to 1.0 (loud speech)
    /// Typical: 0.05-0.15 for normal conversation
    private let vadEnergyThreshold: Float = 0.08

    /// Minimum sustained voice duration to trigger barge-in (250ms reduces false positives)
    private let minVoiceDuration: TimeInterval = 0.25

    // MARK: - State

    /// Whether barge-in detection is currently armed (only during TTS playback)
    @Published private(set) var isArmed: Bool = false

    /// Timestamp when current voice activity started (nil if no activity)
    private var voiceStartTime: Date?

    /// Last detected energy level (for debugging/calibration)
    @Published private(set) var lastEnergyLevel: Float = 0.0

    /// Callback when barge-in is detected (sustained voice >250ms)
    var onBargeInDetected: (() -> Void)?

    /// Audio engine input tap for monitoring
    private weak var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // MARK: - Public Methods

    /// Arm barge-in detection during TTS playback.
    ///
    /// Call this when TTS starts playing. Detector will monitor mic input for sustained voice activity.
    /// On detection, calls onBargeInDetected callback.
    ///
    /// - Parameter audioEngine: The AVAudioEngine to tap for input monitoring
    func arm(audioEngine: AVAudioEngine) {
        guard !isArmed else {
            print("⚠️ BargeInDetector: already armed, ignoring")
            return
        }

        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        self.inputNode = inputNode

        // Must use the node's actual native format, not a hardcoded one - installTap
        // with a mismatched format crashes AVAudioEngine with an uncatchable
        // NSException ("Failed to create tap due to format mismatch"), same hazard
        // WakeWordManager.beginSession() already guards against.
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("❌ BargeInDetector: invalid input format (\(format)), aborting arm")
            return
        }

        let bufferSize: AVAudioFrameCount = 1024 // ~23ms at 44.1kHz

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self = self, self.isArmed else { return }
            self.processAudioBuffer(buffer)
        }

        isArmed = true
        voiceStartTime = nil
        print("✅ BargeInDetector: armed")
    }

    /// Disarm barge-in detection (call when TTS finishes or is cancelled).
    func disarm() {
        guard isArmed else { return }

        // Remove tap from input node
        inputNode?.removeTap(onBus: 0)

        isArmed = false
        voiceStartTime = nil
        lastEnergyLevel = 0.0

        print("✅ BargeInDetector: disarmed")
    }

    // MARK: - Private Methods

    /// Process audio buffer and detect voice activity.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let samples = channelData[0] // Mono channel

        // Calculate RMS energy of buffer
        var sum: Float = 0.0
        for i in 0..<frames {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))

        // Update energy level for monitoring
        DispatchQueue.main.async {
            self.lastEnergyLevel = rms
        }

        // Voice Activity Detection: Is energy above threshold?
        let isVoiceActive = rms > vadEnergyThreshold

        if isVoiceActive {
            // Voice detected
            if voiceStartTime == nil {
                // Start of new voice activity
                voiceStartTime = Date()
                print("🎤 BargeInDetector: voice activity started (energy: \(String(format: "%.3f", rms)))")
            } else {
                // Voice continuing - check if sustained long enough
                let voiceDuration = Date().timeIntervalSince(voiceStartTime!)

                if voiceDuration >= minVoiceDuration {
                    // Sustained voice detected for >250ms = BARGE-IN!
                    print("🚨 BargeInDetector: BARGE-IN DETECTED (duration: \(String(format: "%.0f", voiceDuration * 1000))ms, energy: \(String(format: "%.3f", rms)))")

                    // Trigger callback on main thread
                    DispatchQueue.main.async {
                        self.triggerBargeIn()
                    }
                }
            }
        } else {
            // Silence detected - reset voice activity tracking
            if voiceStartTime != nil {
                let voiceDuration = Date().timeIntervalSince(voiceStartTime!)
                print("🤫 BargeInDetector: voice activity ended (duration: \(String(format: "%.0f", voiceDuration * 1000))ms, too short for barge-in)")
                voiceStartTime = nil
            }
        }
    }

    /// Trigger barge-in callback (called on main thread).
    private func triggerBargeIn() {
        guard isArmed else { return }

        // Disarm immediately to prevent multiple triggers
        disarm()

        // Call registered callback
        onBargeInDetected?()
    }

    // MARK: - Calibration Helpers

    /// Get current VAD threshold (for debugging/tuning).
    var currentThreshold: Float {
        return vadEnergyThreshold
    }

    /// Check if current energy would trigger VAD (for testing).
    func wouldTriggerVAD(energy: Float) -> Bool {
        return energy > vadEnergyThreshold
    }
}

// MARK: - Integration Notes

/*
 Integration with ConversationOrchestrator:

 1. Initialize BargeInDetector in ConversationOrchestrator
 2. Set onBargeInDetected callback to cancel TTS and transition to listening
 3. Arm detector when state transitions to .speaking
 4. Disarm when TTS completes or state changes

 Example:

 ```swift
 class ConversationOrchestrator {
     private let bargeInDetector = BargeInDetector()
     private var audioEngine: AVAudioEngine?

     init(ttsManager: NativeTTSManager) {
         // ... existing init

         // Wire barge-in callback
         bargeInDetector.onBargeInDetected = { [weak self] in
             Task { @MainActor in
                 await self?.handleBargeIn()
             }
         }
     }

     private func processWithSSE(...) async throws {
         // ... existing code ...

         // Before speaking
         state = .speaking
         currentResponse = response.answer

         // ARM BARGE-IN DETECTOR
         if let engine = audioEngine {
             bargeInDetector.arm(audioEngine: engine)
         }

         try await speakResponse(response.answer)

         // DISARM after speaking
         bargeInDetector.disarm()
     }

     private func handleBargeIn() async {
         print("🚨 ConversationOrchestrator: barge-in detected, cancelling TTS")

         // Cancel current TTS
         ttsManager.stopSpeaking()

         // Transition to listening for new query
         state = .listening

         // Start capturing new query
         // ... trigger speech recognition ...
     }
 }
 ```

 Testing:
 - Speak loudly while Jarvis is responding
 - Verify TTS stops within 150ms of start of speech
 - Verify new query is captured
 - Test false positive rate with coughs, background noise
 */
