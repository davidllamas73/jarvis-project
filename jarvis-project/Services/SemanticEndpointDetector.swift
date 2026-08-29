import Foundation

/// Semantic Endpointing: Dynamic silence thresholds based on utterance completeness.
///
/// The endpointing problem: Fixed silence timeouts (e.g., 1000ms) cause:
/// - False turn-endings when user pauses mid-thought
/// - Extended latency when user finishes speaking but system waits full timeout
///
/// Solution: Analyze partial transcription semantically to determine likely completeness:
/// - Incomplete phrases ("what were my...") → extend timeout to 1500ms
/// - Complete sentences ("what were my achievements?") → short timeout (500ms)
/// - Default/ambiguous → standard timeout (1000ms)
///
/// Design:
/// - Rule-based heuristics (lightweight, no ML model needed)
/// - Analyzes last few words for incompleteness markers
/// - Returns dynamic silence threshold: 500ms / 1000ms / 1500ms
///
/// Integration:
/// - Call shouldEndUtterance() on every partial transcription update
/// - Use returned timeout for speech recognition session
/// - Industry standard: LiveKit achieves 85% reduction in false interruptions
///
/// References:
/// - LiveKit End-of-Turn: https://livekit.com/blog/using-a-transformer-to-improve-end-of-turn-detection
/// - Deepgram utterance_end_ms: https://developers.deepgram.com/docs/utterance-end
/// - Voice protocol design: wiki/concepts/voice-conversation-protocol-design.md
/// Stateless rule-based classifier - no @Published state, so no ObservableObject
/// conformance (Swift can't synthesize objectWillChange without at least one).
@MainActor
class SemanticEndpointDetector {

    // MARK: - Configuration

    /// Short timeout for clearly complete utterances (500ms)
    private let shortTimeout: TimeInterval = 0.5

    /// Standard timeout for ambiguous cases (1000ms)
    private let standardTimeout: TimeInterval = 1.0

    /// Extended timeout for incomplete phrases (1500ms)
    private let extendedTimeout: TimeInterval = 1.5

    // MARK: - Incomplete Phrase Patterns

    /// Words/phrases that suggest user will continue speaking
    private let incompletePatterns: [String] = [
        // Question starters (incomplete)
        "what", "who", "when", "where", "why", "how",
        "tell me", "show me", "give me", "find me",
        "can you", "could you", "would you", "will you",
        "do you", "did you", "have you", "has anyone",

        // Conjunctions/connectors (mid-thought)
        "but", "and", "or", "so", "because", "since",
        "if", "when", "while", "although", "however",
        "therefore", "moreover", "furthermore", "also",

        // Prepositions (hanging)
        "in", "on", "at", "to", "for", "from", "with",
        "about", "during", "between", "among", "through",

        // Incomplete verb phrases
        "i want", "i need", "i would", "i should", "i could",
        "i'm going", "i was", "i have", "i had",
        "let's", "let me", "we should", "we need",

        // Incomplete comparisons
        "more than", "less than", "as much as", "compared to",
        "similar to", "different from", "better than"
    ]

    // MARK: - Complete Phrase Patterns

    /// Words/phrases that suggest utterance is complete
    private let completePatterns: [String] = [
        // Politeness markers
        "thank you", "thanks", "please", "ok", "okay",
        "yes", "no", "sure", "got it", "understood",
        "never mind", "that's all", "that's it",

        // Confirmations
        "done", "finished", "complete", "ready",
        "sounds good", "looks good", "perfect",

        // Closings
        "goodbye", "bye", "see you", "later",
        "stop", "cancel", "quit", "exit"
    ]

    // MARK: - Public API

    /// Determine optimal silence threshold based on partial transcription.
    ///
    /// - Parameter partialTranscription: Current partial transcript from speech recognizer
    /// - Returns: Recommended silence timeout (0.5s / 1.0s / 1.5s)
    func shouldEndUtterance(_ partialTranscription: String) -> TimeInterval {
        let trimmed = partialTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or very short = standard timeout
        guard !trimmed.isEmpty else {
            return standardTimeout
        }

        let lowercased = trimmed.lowercased()

        // Check for complete patterns first (higher confidence)
        if endsWithCompletePhrase(lowercased) {
            print("🔚 SemanticEndpoint: Complete phrase detected → \(shortTimeout)s timeout")
            return shortTimeout
        }

        // Check for incomplete patterns
        if endsWithIncompletePhrase(lowercased) {
            print("⏳ SemanticEndpoint: Incomplete phrase detected → \(extendedTimeout)s timeout")
            return extendedTimeout
        }

        // Check for question mark or period
        if trimmed.hasSuffix("?") || trimmed.hasSuffix(".") {
            print("🔚 SemanticEndpoint: Punctuation detected → \(shortTimeout)s timeout")
            return shortTimeout
        }

        // Default case: standard timeout
        print("⏱️ SemanticEndpoint: Ambiguous → \(standardTimeout)s timeout")
        return standardTimeout
    }

    // MARK: - Private Helpers

    /// Check if text ends with a complete phrase pattern
    private func endsWithCompletePhrase(_ lowercased: String) -> Bool {
        return completePatterns.contains { pattern in
            lowercased.hasSuffix(pattern)
        }
    }

    /// Check if text ends with an incomplete phrase pattern
    private func endsWithIncompletePhrase(_ lowercased: String) -> Bool {
        // Check exact suffix match
        if incompletePatterns.contains(where: { lowercased.hasSuffix($0) }) {
            return true
        }

        // Check if ends with single incomplete word
        let words = lowercased.split(separator: " ")
        guard let lastWord = words.last else {
            return false
        }

        return incompletePatterns.contains { pattern in
            // Single-word incomplete patterns
            pattern.split(separator: " ").count == 1 && pattern == String(lastWord)
        }
    }

    // MARK: - Diagnostic Helpers

    /// Analyze transcription and return detailed breakdown (for debugging)
    func analyzeUtterance(_ transcription: String) -> UtteranceAnalysis {
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let isComplete = endsWithCompletePhrase(lowercased) || trimmed.hasSuffix("?") || trimmed.hasSuffix(".")
        let isIncomplete = endsWithIncompletePhrase(lowercased)
        let timeout = shouldEndUtterance(transcription)

        var matchedPattern: String? = nil
        if isComplete {
            matchedPattern = completePatterns.first { lowercased.hasSuffix($0) }
            if matchedPattern == nil && (trimmed.hasSuffix("?") || trimmed.hasSuffix(".")) {
                matchedPattern = "punctuation"
            }
        } else if isIncomplete {
            matchedPattern = incompletePatterns.first { lowercased.hasSuffix($0) }
        }

        return UtteranceAnalysis(
            transcription: transcription,
            isComplete: isComplete,
            isIncomplete: isIncomplete,
            timeout: timeout,
            matchedPattern: matchedPattern
        )
    }
}

// MARK: - Supporting Types

/// Detailed analysis result for diagnostics
struct UtteranceAnalysis {
    let transcription: String
    let isComplete: Bool
    let isIncomplete: Bool
    let timeout: TimeInterval
    let matchedPattern: String?

    var description: String {
        var result = "Utterance: '\(transcription)'\n"
        result += "Complete: \(isComplete) | Incomplete: \(isIncomplete)\n"
        result += "Timeout: \(timeout)s\n"
        if let pattern = matchedPattern {
            result += "Matched pattern: '\(pattern)'\n"
        }
        return result
    }
}

// MARK: - Example Usage
/*
 Usage in SpeechRecognitionManager or ContentView:

 class SpeechManager {
     private let endpointDetector = SemanticEndpointDetector()
     private var silenceTimer: Timer?

     func onPartialResult(_ transcription: String) {
         // Cancel existing timer
         silenceTimer?.invalidate()

         // Get dynamic timeout
         let timeout = endpointDetector.shouldEndUtterance(transcription)

         // Set new timer with dynamic threshold
         silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
             self?.finalizeUtterance(transcription)
         }
     }

     func finalizeUtterance(_ text: String) {
         // User has stopped speaking, process query
         processQuery(text)
     }
 }
 */
