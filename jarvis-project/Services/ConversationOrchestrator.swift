import Foundation
import Combine
import AVFoundation

/// Conversation state for natural async voice interactions
enum ConversationState: Equatable {
    case idle                    // Not in conversation
    case listening               // Capturing user query
    case acknowledged            // Query received, acknowledged verbally
    case processing              // Background processing with optional updates
    case speaking                // TTS playing response
    case error(String)           // Recoverable error

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .acknowledged: return "Acknowledged"
        case .processing: return "Processing"
        case .speaking: return "Speaking"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Orchestrates natural conversation flow with immediate acknowledgment and background processing.
///
/// Key behaviors:
/// - Immediate acknowledgment (<500ms) for all queries via TTS
/// - Background processing with optional progress updates
/// - State machine enforcement (mutual exclusion on transitions)
/// - Integrates with AudioSessionManager for iOS screen lock prevention
///
/// Usage:
///   let orchestrator = ConversationOrchestrator()
///   await orchestrator.processQuery("What were my achievements?")
///
/// This eliminates awkward silence during long queries (10-15s agent path).
@MainActor
class ConversationOrchestrator: ObservableObject {
    @Published private(set) var state: ConversationState = .idle
    @Published private(set) var currentResponse: String = ""
    @Published private(set) var isProcessing: Bool = false

    private let apiClient = JarvisAPIClient.shared
    private let ttsManager: NativeTTSManager
    private let audioSessionManager = AudioSessionManager.shared
    private let bargeInDetector = BargeInDetector()
    private var currentTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Reference to AVAudioEngine for barge-in detection (must be set externally)
    weak var audioEngine: AVAudioEngine?

    /// Callback when user interrupts (barge-in) - should start new query capture
    var onBargeIn: (() -> Void)?

    init(ttsManager: NativeTTSManager) {
        self.ttsManager = ttsManager

        // Wire barge-in callback
        bargeInDetector.onBargeInDetected = { [weak self] in
            Task { @MainActor in
                await self?.handleBargeIn()
            }
        }
    }

    /// Process user query with immediate acknowledgment and background execution.
    ///
    /// Flow:
    /// 1. Immediate acknowledgment (<500ms TTS)
    /// 2. Background processing (potentially 10-15s)
    /// 3. Optional progress update (if >8s)
    /// 4. Speak final response
    /// 5. Return to idle
    ///
    /// Cancellation: Safe to call cancel() during processing - will clean up gracefully.
    func processQuery(_ query: String, sessionId: String) async throws {
        // Cancel any existing task
        cancel()

        // Update state
        state = .acknowledged
        isProcessing = true
        currentResponse = ""

        // Enable voice conversation mode (iOS screen lock prevention)
        audioSessionManager.enableVoiceConversationMode()

        // Create new processing task
        currentTask = Task {
            do {
                // Use SSE streaming endpoint for immediate acknowledgment
                try await processWithSSE(query: query, sessionId: sessionId)

                // Success - return to idle
                await MainActor.run {
                    state = .idle
                    isProcessing = false
                    audioSessionManager.disableVoiceConversationMode()
                }
            } catch is CancellationError {
                // User cancelled - clean up gracefully
                print("⚠️ ConversationOrchestrator: query cancelled")
                await MainActor.run {
                    state = .idle
                    isProcessing = false
                    audioSessionManager.disableVoiceConversationMode()
                }
            } catch {
                // Error - report to user. Fully handled here (state + cleanup), so
                // not rethrown: currentTask is Task<Void, Never> since the caller
                // awaits its .value without try.
                print("❌ ConversationOrchestrator: error - \(error)")
                await MainActor.run {
                    state = .error(error.localizedDescription)
                    isProcessing = false
                    audioSessionManager.disableVoiceConversationMode()
                }
            }
        }

        await currentTask?.value
    }

    /// Process query using SSE streaming endpoint with immediate acknowledgment.
    private func processWithSSE(query: String, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // For Phase 2, we'll use the non-streaming endpoint and simulate acknowledgment
        // TODO Phase 2.5: Implement true SSE client in JarvisAPIClient

        // 1. Immediate acknowledgment (simulated for now)
        let ackText = generateAcknowledgment(for: query)
        state = .acknowledged
        try await speakImmediate(ackText)

        guard !Task.isCancelled else { throw CancellationError() }

        // 2. Background processing
        state = .processing

        // Start processing task
        let processingTask = Task {
            try await apiClient.orchestrate(query: query, sessionId: sessionId)
        }

        // 3. Optional progress update (if >8s)
        var progressSent = false
        for iteration in 0..<16 {  // Check every 0.5s for 8s total
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            if processingTask.isCancelled || Task.isCancelled {
                processingTask.cancel()
                throw CancellationError()
            }
            // Check if processing task completed
            // Swift doesn't have Task.done, so we rely on timeout
            if !progressSent && iteration == 15 {  // 8 seconds elapsed
                progressSent = true
                try await speakImmediate("Still working on that")
            }
        }

        // 4. Get result
        let response = try await processingTask.value

        guard !Task.isCancelled else { throw CancellationError() }

        // 5. Speak final response
        state = .speaking
        currentResponse = response.answer
        try await speakResponse(response.answer)
    }

    /// Generate context-aware acknowledgment (matches backend logic).
    private func generateAcknowledgment(for query: String) -> String {
        let queryLower = query.lowercased()

        // Search/find queries
        if queryLower.contains("search") || queryLower.contains("find") || queryLower.contains("look for") {
            return "Let me search for that"
        }

        // Information queries
        if queryLower.hasPrefix("what") || queryLower.contains(" what ") {
            return "Let me look that up"
        } else if queryLower.hasPrefix("who") || queryLower.contains(" who ") {
            return "Let me check"
        } else if queryLower.hasPrefix("how") || queryLower.contains(" how ") {
            return "Let me see"
        } else if queryLower.hasPrefix("where") || queryLower.contains(" where ") {
            return "Let me find that"
        } else if queryLower.hasPrefix("when") || queryLower.contains(" when ") {
            return "Let me check the timeline"
        }

        // Achievements, career, records
        if queryLower.contains("achievement") || queryLower.contains("career") ||
           queryLower.contains("experience") || queryLower.contains("work") {
            return "Let me check your records"
        }

        // Email, message, draft
        if queryLower.contains("email") || queryLower.contains("message") ||
           queryLower.contains("draft") || queryLower.contains("write") {
            return "I'll draft that for you"
        }

        // Analysis, comparison
        if queryLower.contains("analyze") || queryLower.contains("compare") ||
           queryLower.contains("difference") || queryLower.contains("versus") {
            return "Let me analyze that"
        }

        // Default generic acknowledgment
        return "One moment"
    }

    /// Speak text immediately (for acknowledgments and progress updates).
    private func speakImmediate(_ text: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Use native TTS for immediate playback (no API roundtrip)
        try await ttsManager.speak(text)
    }

    /// Speak full response (may use streaming in future).
    private func speakResponse(_ text: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Arm barge-in detector if audio engine is available
        if let engine = audioEngine {
            bargeInDetector.arm(audioEngine: engine)
        }

        // For now, speak full text
        // TODO Phase 2.5: Implement sentence-by-sentence streaming
        try await ttsManager.speak(text)

        // Disarm barge-in detector after speaking completes
        bargeInDetector.disarm()
    }

    /// Cancel current processing task.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        bargeInDetector.disarm()
        ttsManager.stop()
        state = .idle
        isProcessing = false
        audioSessionManager.disableVoiceConversationMode()
    }

    /// Handle barge-in (user interrupts Jarvis mid-response).
    ///
    /// Called when BargeInDetector detects sustained voice activity during TTS playback.
    /// Cancels current TTS, transitions to listening, and triggers new query capture.
    private func handleBargeIn() async {
        print("🚨 ConversationOrchestrator: barge-in detected, cancelling TTS")

        // Cancel current TTS and disarm detector
        ttsManager.stop()
        bargeInDetector.disarm()

        // Cancel current processing task
        currentTask?.cancel()
        currentTask = nil

        // Transition to listening for new query
        state = .listening
        currentResponse = ""
        isProcessing = false

        // Trigger callback to start capturing new query
        // (ContentView will handle starting speech recognition)
        onBargeIn?()
    }

    /// Check if orchestrator is currently busy.
    var isBusy: Bool {
        return state != .idle && state != .error("")
    }
}

/// Response model matching backend OrchestResponse
struct OrchestrationResponse: Codable {
    let answer: String
    let path: String
    let confidence: Double
    let conversationId: String?

    enum CodingKeys: String, CodingKey {
        case answer
        case path
        case confidence
        case conversationId = "conversation_id"
    }
}

/// Extension to JarvisAPIClient for orchestration endpoint
extension JarvisAPIClient {
    func orchestrate(query: String, sessionId: String, useAgent: Bool? = nil) async throws -> OrchestrationResponse {
        struct OrchestRequest: Codable {
            let query: String
            let useAgent: Bool?
            let conversationId: String?

            enum CodingKeys: String, CodingKey {
                case query
                case useAgent = "use_agent"
                case conversationId = "conversation_id"
            }
        }

        let requestBody = OrchestRequest(
            query: query,
            useAgent: useAgent,
            conversationId: sessionId
        )

        let bodyData = try JSONEncoder().encode(requestBody)

        // Use existing makeRequest pattern - requires making it internal
        // For now, manually construct request (matches makeRequest implementation)
        guard let url = URL(string: "https://18.142.241.151:8443/api/v1/orchestrate") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Add auth if available
        if let token = UserDefaults.standard.string(forKey: "jarvis_access_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Use shared session with self-signed cert support
        let sessionDelegate = SelfSignedCertificateDelegate()
        let config = URLSessionConfiguration.default
        let urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.detail)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrchestrationResponse.self, from: data)
    }
}
