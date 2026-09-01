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

    /// Reference to WakeWordManager, set externally alongside audioEngine.
    ///
    /// WakeWordManager and BargeInDetector both install taps on the same
    /// AVAudioEngine.inputNode/bus 0 - a hardware resource with exactly one
    /// tap slot, not something either class can assume it owns exclusively.
    /// The foreground query flow already coordinates this correctly via
    /// suspendForActiveQuery()/resumeAfterActiveQuery() in ContentView, but
    /// deliverBackgroundResult() below runs on its own schedule (whenever a
    /// background task finishes) and has no natural place in that flow -
    /// without this reference it can arm BargeInDetector's tap while
    /// WakeWordManager is mid-session on the same node, crashing CoreAudio's
    /// "nullptr == Tap()" assertion.
    weak var wakeWordManager: WakeWordManager?

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
    /// 1. Classify with V2 (fast, accurate)
    /// 2. Immediate acknowledgment (<500ms TTS)
    /// 3. Route to appropriate handler based on tier
    /// 4. Speak final response
    /// 5. Return to idle
    ///
    /// Cancellation: Safe to call cancel() during processing - will clean up gracefully.
    func processQuery(_ query: String, sessionId: String) async throws {
        // Cancel any existing task
        cancel()

        // Update state
        state = .listening
        isProcessing = true
        currentResponse = ""

        // Enable voice conversation mode (iOS screen lock prevention)
        audioSessionManager.enableVoiceConversationMode()

        // Create new processing task
        currentTask = Task {
            do {
                // Use V2 classification for better routing
                try await processWithV2Classification(query: query, sessionId: sessionId)

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

    /// Process query with V2 classification for better routing.
    private func processWithV2Classification(query: String, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // 1. Classify with V2 (for better accuracy and performance)
        let classification: ClassifyV2Response
        do {
            classification = try await apiClient.classifyV2(query: query, enableLlm: false)
            print("📊 V2 Classification: tier=\(classification.tier), confidence=\(classification.confidence), method=\(classification.method), latency=\(classification.latencyMs)ms")
        } catch {
            print("⚠️ V2 classification failed: \(error), falling back to V1")
            // Fallback to old /tiered endpoint if V2 fails
            try await processWithSSE(query: query, sessionId: sessionId)
            return
        }

        // 2. Immediate acknowledgment for all queries
        let ack = generateAcknowledgmentV2(for: classification.tier)
        state = .acknowledged
        try await speakImmediate(ack)

        guard !Task.isCancelled else { throw CancellationError() }

        // 3. Route based on tier
        state = .processing
        switch classification.tier {
        case "conversational":
            // Fast path - simple greeting/chat
            try await handleConversationalQuery(query, classification: classification, sessionId: sessionId)
        case "knowledge":
            // RAG path - search second brain
            try await handleKnowledgeQuery(query, classification: classification, sessionId: sessionId)
        case "research":
            // Web search path (background task)
            try await handleResearchQuery(query, classification: classification, sessionId: sessionId)
        case "task":
            // Agent path - tool use
            try await handleTaskQuery(query, classification: classification, sessionId: sessionId)
        default:
            print("⚠️ Unknown tier: \(classification.tier), using default handler")
            try await handleKnowledgeQuery(query, classification: classification, sessionId: sessionId)
        }
    }

    /// Generate tier-specific acknowledgment for V2 classifier.
    private func generateAcknowledgmentV2(for tier: String) -> String {
        switch tier {
        case "conversational":
            return ["Sure", "Okay", "Yes"].randomElement() ?? "Sure"
        case "knowledge":
            return ["Let me check that", "Looking that up", "One moment"].randomElement() ?? "Let me check that"
        case "research":
            return ["I'll research that for you", "Let me look into that", "Researching now"].randomElement() ?? "I'll research that for you"
        case "task":
            return ["Running that now", "On it", "Starting that task"].randomElement() ?? "Running that now"
        default:
            return "Okay"
        }
    }

    /// Handle conversational queries (greetings, simple chat).
    private func handleConversationalQuery(_ query: String, classification: ClassifyV2Response, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Simple conversational response - use chat endpoint for context
        do {
            let response = try await apiClient.chat(query: query)
            currentResponse = response.answer
            state = .speaking
            try await speakResponse(response.answer)
        } catch {
            // Fallback to simple response if chat fails
            currentResponse = "I'm here and ready to help!"
            state = .speaking
            try await speakResponse(currentResponse)
        }
    }

    /// Handle knowledge queries (search second brain).
    private func handleKnowledgeQuery(_ query: String, classification: ClassifyV2Response, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Search second brain (existing RAG logic)
        do {
            let response = try await apiClient.chat(query: query)
            currentResponse = response.answer
            state = .speaking
            try await speakResponse(response.answer)
        } catch {
            currentResponse = "I couldn't find information on that"
            state = .speaking
            try await speakResponse(currentResponse)
        }
    }

    /// Handle research queries (web search - background task).
    private func handleResearchQuery(_ query: String, classification: ClassifyV2Response, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Web search requires background processing
        // For now, route to task handler which supports background
        try await handleTaskQuery(query, classification: classification, sessionId: sessionId)
    }

    /// Handle task queries (agent path with tool use).
    private func handleTaskQuery(_ query: String, classification: ClassifyV2Response, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // Agent path with tool use - may be background or foreground
        do {
            // Use streaming for better UX
            var fullAnswer = ""
            for try await event in apiClient.executeCodeStream(query: query, sessionId: sessionId) {
                switch event {
                case .textDelta(let text):
                    fullAnswer += text
                    currentResponse = fullAnswer
                    // Optionally speak chunks as they arrive in future
                case .done(let response):
                    currentResponse = response.answer
                    state = .speaking
                    try await speakResponse(response.answer)
                case .error(let message):
                    currentResponse = "Error: \(message)"
                    state = .speaking
                    try await speakResponse(currentResponse)
                }
            }
        } catch {
            currentResponse = "Task execution failed: \(error.localizedDescription)"
            state = .speaking
            try await speakResponse(currentResponse)
        }
    }

    /// Process query using SSE streaming endpoint with immediate acknowledgment.
    /// This is the V1 fallback path - kept for backward compatibility.
    private func processWithSSE(query: String, sessionId: String) async throws {
        guard !Task.isCancelled else { throw CancellationError() }

        // For Phase 2, we'll use the non-streaming endpoint and simulate acknowledgment
        // TODO Phase 2.5: Implement true SSE client in JarvisAPIClient

        // 1. Immediate acknowledgment (simulated for now)
        let ackText = generateAcknowledgment(for: query)
        state = .acknowledged
        try await speakImmediate(ackText)

        guard !Task.isCancelled else { throw CancellationError() }

        // 2. Background processing, with an optional progress update if it runs
        // past 8s. Races the actual orchestrate() call against an 8s timer in a
        // task group instead of always sleeping the full window - the previous
        // version slept through all 16 iterations unconditionally even after the
        // response was ready, silently delaying every reply by up to 8s.
        state = .processing

        let response: OrchestrationResponse = try await withThrowingTaskGroup(of: OrchestrationResponseOrTimeout.self) { group in
            group.addTask {
                .response(try await self.apiClient.orchestrate(query: query, sessionId: sessionId))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                return .timeout
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }

            switch first {
            case .response(let response):
                group.cancelAll()
                return response
            case .timeout:
                guard !Task.isCancelled else {
                    group.cancelAll()
                    throw CancellationError()
                }
                try await self.speakImmediate("Still working on that")
                guard let second = try await group.next(), case .response(let response) = second else {
                    throw CancellationError()
                }
                return response
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // 4. Check if background task was triggered
        if response.needsBackground, let taskId = response.taskId {
            // Background mode: speak interim response and start polling
            state = .speaking
            currentResponse = response.answer
            try await speakResponse(response.answer)

            // Kick off independent background poller (fire-and-forget)
            Task.detached { [weak self] in
                await self?.pollBackgroundTask(taskId: taskId)
            }

            // Return to idle immediately (wake word stays armed)
            return
        }

        // 5. Fast path: speak final response
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

    /// Poll background task until completion and deliver result.
    ///
    /// Runs in detached task - continues polling independently of main conversation flow.
    /// Delivers result politely: waits if currently speaking/processing, then interrupts
    /// with background result.
    private func pollBackgroundTask(taskId: String) async {
        while true {
            // Poll every 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            guard let status = try? await apiClient.getTaskStatus(taskId: taskId) else {
                // Network error or task not found - retry
                continue
            }

            switch status.status {
            case "done", "failed":
                // Task complete - deliver result
                await deliverBackgroundResult(status)
                return
            default:
                // Still pending/running - keep polling
                continue
            }
        }
    }

    /// Deliver background task result politely.
    ///
    /// Waits if currently speaking/processing, then delivers result via TTS.
    /// This implements the "get back to you" promise - Jarvis proactively
    /// interrupts with the answer when ready.
    private func deliverBackgroundResult(_ status: TaskStatusResponse) async {
        let text: String
        if status.status == "done" {
            text = status.result ?? "I finished looking into that but didn't find anything"
        } else {
            text = "I wasn't able to complete that search: \(status.error ?? "unknown error")"
        }

        // Wait if currently speaking/processing (be polite, don't interrupt)
        while state == .speaking || state == .processing {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        }

        // Deliver result
        currentResponse = text
        state = .speaking

        // Enable voice conversation mode for result delivery
        audioSessionManager.enableVoiceConversationMode()

        // Suspend wake-word listening before touching the shared input node's
        // tap - same coordination ContentView already does around foreground
        // queries, needed here too since this runs on its own schedule.
        wakeWordManager?.suspendForActiveQuery()

        do {
            try await speakResponse(text)
            state = .idle
            audioSessionManager.disableVoiceConversationMode()
        } catch {
            print("❌ Failed to deliver background result: \(error)")
            state = .error("Failed to deliver result: \(error.localizedDescription)")
            audioSessionManager.disableVoiceConversationMode()
        }

        wakeWordManager?.resumeAfterActiveQuery()
    }

    /// Check if orchestrator is currently busy.
    var isBusy: Bool {
        return state != .idle && state != .error("")
    }
}

/// Result of racing the orchestrate() call against an 8s progress-update timer
/// in processWithSSE() - lets the task group tell which one finished first.
private enum OrchestrationResponseOrTimeout {
    case response(OrchestrationResponse)
    case timeout
}

/// Response model matching backend TieredOrchestResponse
struct OrchestrationResponse: Codable {
    let answer: String
    let tier: String
    let path: String
    let confidence: Double
    let conversationId: String?
    let acknowledgment: String?
    let needsBackground: Bool
    let taskId: String?

    enum CodingKeys: String, CodingKey {
        case answer
        case tier
        case path
        case confidence
        case conversationId = "conversation_id"
        case acknowledgment
        case needsBackground = "needs_background"
        case taskId = "task_id"
    }
}

struct TaskStatusResponse: Codable {
    let taskId: String
    let status: String  // pending | running | done | failed
    let result: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case status
        case result
        case error
    }
}

/// Extension to JarvisAPIClient for orchestration endpoint
extension JarvisAPIClient {
    func orchestrate(query: String, sessionId: String) async throws -> OrchestrationResponse {
        struct OrchestRequest: Codable {
            let query: String
            let conversationId: String?

            enum CodingKeys: String, CodingKey {
                case query
                case conversationId = "conversation_id"
            }
        }

        let requestBody = OrchestRequest(
            query: query,
            conversationId: sessionId
        )

        let bodyData = try JSONEncoder().encode(requestBody)

        // UPDATED: Changed from /orchestrate to /orchestrate/tiered
        guard let url = URL(string: "\(self.baseURL)/orchestrate/tiered") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Auth not required for /orchestrate/tiered per backend config
        // but include it if available for future compatibility
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

    func getTaskStatus(taskId: String) async throws -> TaskStatusResponse {
        guard let url = URL(string: "https://18.142.241.151:8443/api/v1/orchestrate/tasks/\(taskId)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

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
        return try decoder.decode(TaskStatusResponse.self, from: data)
    }
}
