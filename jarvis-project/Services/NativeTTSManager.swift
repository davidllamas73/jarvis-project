//
//  NativeTTSManager.swift
//  jarvis-project
//
//  Created by David Llamas on 14/08/2026.
//

import Foundation
import AVFoundation
import Combine
import os

private let perfLog = Logger(subsystem: "com.jarvis.debug", category: "perf")

/// Native text-to-speech using AVSpeechSynthesizer
/// Zero latency, no API calls, works offline
///
/// Everything here is @MainActor-isolated on purpose: AVSpeechSynthesizerDelegate
/// callbacks arrive on an internal AVFoundation thread, not the main thread, and
/// pendingUtteranceCount/isSpeaking used to be touched from both that thread and
/// the calling Task without synchronization - a real data race that Xcode was
/// flagging as a "Hang Risk" (QoS priority inversion) during streaming speech.
@MainActor
class NativeTTSManager: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// Jamie (Premium) UK - identifier resolves to "Malcolm" internally, verified via:
    /// swift -e 'AVSpeechSynthesisVoice.speechVoices()...' on the target Mac
    ///
    /// Looked up ONCE here in init() (a plain synchronous context) rather than fresh
    /// on every utterance. AVSpeechSynthesisVoice(identifier:) makes a synchronous
    /// call into Apple's Accessibility subsystem internally - constructing it inside
    /// an async Task (as queueUtterance() used to, once per sentence while streaming)
    /// is a confirmed Apple-side trigger for the "unsafeForcedSync called from Swift
    /// Concurrent context" diagnostic and the Hang Risk warning that came with it
    /// (Apple DTS, developer.apple.com/forums/thread/802423; filed as FB20484368).
    private static let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm")

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
        utterance.voice = Self.voice

        // Configure for natural speech
        utterance.rate = rate  // 0.52 is slightly faster than default but natural
        utterance.pitchMultiplier = pitch
        utterance.volume = 1.0

        isSpeaking = true
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
        }
        isSpeaking = false
        endCurrentGeneration()
    }

    // MARK: - Streaming speech

    /// Number of utterances queued but not yet finished, for the CURRENT streamGeneration.
    /// AVSpeechSynthesizer queues utterances automatically when speak() is called while
    /// it's already speaking, so this just tracks when we can consider playback fully done.
    private var pendingUtteranceCount = 0
    private var allTextQueuedContinuation: CheckedContinuation<Void, Never>?

    /// Bumped on every speakStream()/stop() call. Delegate callbacks capture the
    /// generation that was active when their utterance was queued and no-op if it's
    /// stale by the time they fire - this is what stops a late completion from one
    /// speakStream() call from corrupting the state of a newer, overlapping one (e.g.
    /// the wake word firing again while Jarvis is still speaking the previous answer).
    private var streamGeneration = 0

    /// Temporary perf-measurement flag: true once we've logged the first didStart
    /// for the current streamGeneration, so PERF logging below fires only once per
    /// query instead of once per queued sentence.
    private var hasLoggedFirstSpeechThisGeneration = false

    /// Speaks text as it streams in: buffers until a sentence boundary, then
    /// queues that sentence immediately so speech starts well before the full
    /// response is ready. Returns once every queued sentence has finished playing.
    func speakStream(_ textChunks: AsyncThrowingStream<String, Error>, rate: Float = 0.52, pitch: Float = 1.0) async throws {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        streamGeneration += 1
        let myGeneration = streamGeneration
        pendingUtteranceCount = 0
        allTextQueuedContinuation = nil
        hasLoggedFirstSpeechThisGeneration = false

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
                    queueUtterance(sentence, rate: rate, pitch: pitch, generation: myGeneration)
                }
            }
        }

        // Speak whatever's left that didn't end in punctuation.
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            queueUtterance(remainder, rate: rate, pitch: pitch, generation: myGeneration)
        }

        // Wait for every queued utterance to actually finish playing - but only if
        // we're still the active generation (stop() or a newer speakStream() call
        // may have already superseded us while we were buffering text).
        //
        // Lost-wakeup fix: pendingUtteranceCount can already be back at 0 by the time
        // this closure actually runs (a short trailing utterance can finish - and
        // finishOneQueuedUtterance() can run - in the window between the check above
        // and the continuation being stored below). Without the recheck here, that
        // completion has nothing to resume (allTextQueuedContinuation is still nil at
        // that point) and the continuation stored here would then never be resumed -
        // a permanent hang. Re-checking inside the closure is safe because everything
        // from here to finishOneQueuedUtterance() runs on the same @MainActor with no
        // intervening suspension point, so this recheck and the store are atomic
        // relative to any delegate-driven completion.
        if myGeneration == streamGeneration, pendingUtteranceCount > 0 {
            await withCheckedContinuation { continuation in
                if pendingUtteranceCount == 0 || myGeneration != streamGeneration {
                    continuation.resume()
                } else {
                    allTextQueuedContinuation = continuation
                }
            }
        }
    }

    private func queueUtterance(_ text: String, rate: Float, pitch: Float, generation: Int) {
        guard generation == streamGeneration else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = 1.0

        pendingUtteranceCount += 1
        isSpeaking = true
        pendingGenerations.append(generation)
        synthesizer.speak(utterance)
    }

    /// Tracks which generation each currently-queued AVSpeechUtterance belongs to,
    /// in speak order, so a delegate callback can tell whether the utterance that
    /// just finished was from the still-active generation or a superseded one.
    private var pendingGenerations: [Int] = []

    /// Shared by didFinish/didCancel: pops the oldest pending generation and, if it
    /// matches the currently active one, decrements the count and - once every
    /// queued sentence from that speakStream() call has completed - marks speaking
    /// done and resumes whoever's awaiting the full stream. A stale generation (from
    /// a speakStream()/stop() call that's since been superseded) is a no-op.
    private func finishOneQueuedUtterance() {
        guard !pendingGenerations.isEmpty else { return }
        let finishedGeneration = pendingGenerations.removeFirst()

        guard finishedGeneration == streamGeneration else { return }

        if pendingUtteranceCount > 0 {
            pendingUtteranceCount -= 1
        }
        if pendingUtteranceCount == 0 {
            isSpeaking = false
            allTextQueuedContinuation?.resume()
            allTextQueuedContinuation = nil
        }
    }

    /// Used by stop(): bumps the generation counter so any utterances still in
    /// flight are recognized as stale when their delegate callbacks arrive, clears
    /// the pending queue, and resumes anyone awaiting the current speakStream() call.
    private func endCurrentGeneration() {
        streamGeneration += 1
        pendingUtteranceCount = 0
        pendingGenerations.removeAll()
        allTextQueuedContinuation?.resume()
        allTextQueuedContinuation = nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension NativeTTSManager: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizerDelegate callbacks arrive on an AVFoundation-owned thread,
    // not necessarily the main thread. Hop to the main actor before touching any
    // @MainActor state - this is what actually fixes the data race/hang risk.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            if !self.hasLoggedFirstSpeechThisGeneration {
                self.hasLoggedFirstSpeechThisGeneration = true
                perfLog.fault("PERF: first TTS word started")
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("TTS finished")
        Task { @MainActor in
            self.speechContinuation?.resume()
            self.speechContinuation = nil
            self.finishOneQueuedUtterance()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("TTS cancelled")
        Task { @MainActor in
            self.speechContinuation?.resume()
            self.speechContinuation = nil
            self.finishOneQueuedUtterance()
        }
    }
}
