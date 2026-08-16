//
//  NativeTTSManager.swift
//  jarvis-project
//
//  Created by David Llamas on 14/08/2026.
//

import Foundation
import AVFoundation
import Combine

/// Native text-to-speech using AVSpeechSynthesizer
/// Zero latency, no API calls, works offline
class NativeTTSManager: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    @Published var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak text instantly using native TTS
    func speak(_ text: String, rate: Float = 0.52, pitch: Float = 1.0) async {
        // Stop any ongoing speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // Jamie (Premium) UK - identifier resolves to "Malcolm" internally, verified via:
        // swift -e 'AVSpeechSynthesisVoice.speechVoices()...' on the target Mac
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm")

        // Configure for natural speech
        utterance.rate = rate  // 0.52 is slightly faster than default but natural
        utterance.pitchMultiplier = pitch
        utterance.volume = 1.0

        await MainActor.run {
            isSpeaking = true
        }

        synthesizer.speak(utterance)

        print("Native TTS speaking: '\(text.prefix(50))...'")

        // Wait for speech to finish
        await withCheckedContinuation { continuation in
            // Store continuation to resume when speech finishes
            speechContinuation = continuation
        }
    }

    private var speechContinuation: CheckedContinuation<Void, Never>?

    /// Stop current speech
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
        }
        pendingUtteranceCount = 0
        allTextQueuedContinuation?.resume()
        allTextQueuedContinuation = nil
    }

    // MARK: - Streaming speech

    /// Number of utterances queued but not yet finished. AVSpeechSynthesizer
    /// queues utterances automatically when speak() is called while it's already
    /// speaking, so this just tracks when we can consider playback fully done.
    private var pendingUtteranceCount = 0
    private var allTextQueuedContinuation: CheckedContinuation<Void, Never>?

    /// Speaks text as it streams in: buffers until a sentence boundary, then
    /// queues that sentence immediately so speech starts well before the full
    /// response is ready. Returns once every queued sentence has finished playing.
    func speakStream(_ textChunks: AsyncThrowingStream<String, Error>, rate: Float = 0.52, pitch: Float = 1.0) async throws {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pendingUtteranceCount = 0

        var buffer = ""
        let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

        for try await chunk in textChunks {
            buffer += chunk

            // Peel off complete sentences as they appear, keep the remainder buffered.
            while let boundary = buffer.firstIndex(where: { sentenceEnders.contains($0) }) {
                let sentenceEnd = buffer.index(after: boundary)
                let sentence = String(buffer[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[sentenceEnd...])

                if !sentence.isEmpty {
                    queueUtterance(sentence, rate: rate, pitch: pitch)
                }
            }
        }

        // Speak whatever's left that didn't end in punctuation.
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            queueUtterance(remainder, rate: rate, pitch: pitch)
        }

        // Wait for every queued utterance to actually finish playing.
        if pendingUtteranceCount > 0 {
            await withCheckedContinuation { continuation in
                allTextQueuedContinuation = continuation
            }
        }
    }

    private func queueUtterance(_ text: String, rate: Float, pitch: Float) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm")
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = 1.0

        pendingUtteranceCount += 1
        Task { @MainActor in
            isSpeaking = true
        }
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension NativeTTSManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        print("TTS started")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("TTS finished")
        speechContinuation?.resume()
        speechContinuation = nil
        finishOneQueuedUtterance()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("TTS cancelled")
        speechContinuation?.resume()
        speechContinuation = nil
        finishOneQueuedUtterance()
    }

    /// Shared by didFinish/didCancel: decrements the queue count and, once every
    /// queued sentence from a speakStream() call has completed, marks speaking
    /// done and resumes whoever's awaiting the full stream.
    private func finishOneQueuedUtterance() {
        DispatchQueue.main.async {
            if self.pendingUtteranceCount > 0 {
                self.pendingUtteranceCount -= 1
            }
            if self.pendingUtteranceCount == 0 {
                self.isSpeaking = false
                self.allTextQueuedContinuation?.resume()
                self.allTextQueuedContinuation = nil
            }
        }
    }
}
