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

          print("ð Native TTS speaking: '\(text.prefix(50))...'")

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
      }
  }

  // MARK: - AVSpeechSynthesizerDelegate

  extension NativeTTSManager: AVSpeechSynthesizerDelegate {
      func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
          DispatchQueue.main.async {
              self.isSpeaking = true
          }
          print("ð TTS started")
      }

      func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
          DispatchQueue.main.async {
              self.isSpeaking = false
          }
          print("â TTS finished")
          speechContinuation?.resume()
          speechContinuation = nil
      }

      func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
          DispatchQueue.main.async {
              self.isSpeaking = false
          }
          print("ð TTS cancelled")
          speechContinuation?.resume()
          speechContinuation = nil
      }
  }
