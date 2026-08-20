import Foundation
import Combine
import os

private let sseDebugLog = Logger(subsystem: "com.jarvis.debug", category: "sse")

class JarvisAPIClient: ObservableObject {
    static let shared = JarvisAPIClient()

    // MARK: - Configuration

    private let baseURL: String
    @Published var isAuthenticated = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    private var accessToken: String?
    private var refreshToken: String?

    // Persistent URLSession with certificate delegate
    private let sessionDelegate: SelfSignedCertificateDelegate
    private let urlSession: URLSession
    
    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // MARK: - Initialization

    private init() {
        // Default to localhost, can be configured
        self.baseURL = "https://18.142.241.151:8443/api/v1"

        // Create persistent session with self-signed cert support
        self.sessionDelegate = SelfSignedCertificateDelegate()
        let config = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        
        // Load stored tokens
        loadTokens()
    }

    // MARK: - Token Management

    private func loadTokens() {
        accessToken = UserDefaults.standard.string(forKey: "jarvis_access_token")
        refreshToken = UserDefaults.standard.string(forKey: "jarvis_refresh_token")
        isAuthenticated = accessToken != nil
    }

    private func saveTokens(access: String, refresh: String) {
        accessToken = access
        refreshToken = refresh
        UserDefaults.standard.set(access, forKey: "jarvis_access_token")
        UserDefaults.standard.set(refresh, forKey: "jarvis_refresh_token")
        isAuthenticated = true
    }

    func clearTokens() {
        accessToken = nil
        refreshToken = nil
        UserDefaults.standard.removeObject(forKey: "jarvis_access_token")
        UserDefaults.standard.removeObject(forKey: "jarvis_refresh_token")
        isAuthenticated = false
    }

    // MARK: - Network Requests

    private func makeRequest<T: Decodable>(
        endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        requiresAuth: Bool = true
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add auth header if required
        if requiresAuth, let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = body
        }

        // Use persistent session with self-signed cert support
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to decode error message
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.detail)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Authentication

    func pairDevice(deviceName: String = "Mac", deviceType: String = "mac") async throws {
        connectionStatus = .connecting

        let request = PairDeviceRequest(deviceName: deviceName, deviceType: deviceType)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)

        let response: AuthResponse = try await makeRequest(
            endpoint: "/auth/pair",
            method: "POST",
            body: body,
            requiresAuth: false
        )

        saveTokens(access: response.accessToken, refresh: response.refreshToken)
        connectionStatus = .connected
    }

    func refreshAccessToken() async throws {
        guard let refresh = refreshToken else {
            throw APIError.notAuthenticated
        }

        let body = try JSONEncoder().encode(["refresh_token": refresh])
        let response: AuthResponse = try await makeRequest(
            endpoint: "/auth/refresh",
            method: "POST",
            body: body,
            requiresAuth: false
        )

        saveTokens(access: response.accessToken, refresh: response.refreshToken)
    }

    // MARK: - System

    func checkHealth() async throws -> HealthResponse {
        return try await makeRequest(endpoint: "/system/health", requiresAuth: false)
    }

    // MARK: - Search & Chat

    func search(query: String, nResults: Int = 5, filterType: String? = nil) async throws -> SearchResponse {
        let request = SearchRequest(query: query, nResults: nResults, filterType: filterType)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)

        return try await makeRequest(endpoint: "/search", method: "POST", body: body)
    }

    func chat(query: String, contextSize: Int = 5, conversationId: String? = nil) async throws -> ChatResponse {
        let request = ChatRequest(
            query: query,
            contextSize: contextSize,
            conversationId: conversationId
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)

        return try await makeRequest(endpoint: "/search/chat", method: "POST", body: body)
    }
    
    func executeCode(query: String, sessionId: String, maxTokens: Int? = nil, attachments: [FileAttachment]? = nil) async throws -> CodeExecuteResponse
    {
        let request = CodeExecuteRequest(query: query, sessionId: sessionId, maxTokens: maxTokens, attachments: attachments)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)
        return try await makeRequest(endpoint: "/code/execute", method: "POST", body: body, requiresAuth: false)
    }

    /// Streams the response as it's generated (Server-Sent Events) instead of waiting
    /// for the full answer. Lets the caller start speaking/rendering text immediately.
    func executeCodeStream(query: String, sessionId: String, maxTokens: Int? = nil, attachments: [FileAttachment]? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(self.baseURL)/code/execute/stream") else {
                        continuation.finish(throwing: APIError.invalidURL)
                        return
                    }

                    let request = CodeExecuteRequest(query: query, sessionId: sessionId, maxTokens: maxTokens, attachments: attachments)
                    let encoder = JSONEncoder()
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    let body = try encoder.encode(request)

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = body

                    sseDebugLog.fault("about to call urlSession.bytes(for:)")
                    let (byteStream, response) = try await self.urlSession.bytes(for: urlRequest)
                    sseDebugLog.fault("got response \(String(describing: response), privacy: .public)")

                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        sseDebugLog.fault("bad response, finishing with invalidResponse")
                        continuation.finish(throwing: APIError.invalidResponse)
                        return
                    }

                    sseDebugLog.fault("status \(httpResponse.statusCode, privacy: .public), entering line loop")
                    var lineCount = 0
                    for try await line in byteStream.lines {
                        lineCount += 1
                        sseDebugLog.fault("line #\(lineCount, privacy: .public): '\(line, privacy: .public)'")
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst("data: ".count))
                        guard let jsonData = jsonString.data(using: .utf8),
                              let event = StreamEvent.parse(jsonData) else { continue }

                        continuation.yield(event)

                        if case .done = event {
                            continuation.finish()
                            return
                        }
                        if case .error(let message) = event {
                            continuation.finish(throwing: APIError.serverError(message))
                            return
                        }
                    }

                    sseDebugLog.fault("line loop ended normally after \(lineCount, privacy: .public) lines")
                    continuation.finish()
                } catch {
                    sseDebugLog.fault("outer catch, error=\(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Automation

    func generateInterviewBrief(company: String, person: String? = nil, role: String) async throws -> InterviewBrief {
        let request = InterviewBriefRequest(company: company, person: person, role: role)
        let body = try JSONEncoder().encode(request)

        return try await makeRequest(endpoint: "/brief/interview", method: "POST", body: body)
    }

    func draftEmail(recipient: String, purpose: String, context: String? = nil) async throws -> EmailDraft {
        let request = EmailDraftRequest(recipient: recipient, purpose: purpose, context: context)
        let body = try JSONEncoder().encode(request)

        return try await makeRequest(endpoint: "/brief/email", method: "POST", body: body)
    }

    // MARK: - Voice

    func transcribe(audioBase64: String, language: String = "en") async throws -> TranscribeResponse {
        let request = TranscribeRequest(audioBase64: audioBase64, language: language)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)

        return try await makeRequest(endpoint: "/voice/transcribe", method: "POST", body: body)
    }

    func synthesize(text: String, voiceId: String? = nil) async throws -> SynthesizeResponse {
        let request = SynthesizeRequest(text: text, voiceId: voiceId)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)

        return try await makeRequest(endpoint: "/voice/synthesize", method: "POST", body: body)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case serverError(String)
    case notAuthenticated
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .serverError(let message):
            return message
        case .notAuthenticated:
            return "Not authenticated"
        case .decodingError:
            return "Failed to decode response"
        }
    }
}

struct ErrorResponse: Codable {
    let detail: String
}

// MARK: - Self-Signed Certificate Delegate

class SelfSignedCertificateDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Accept self-signed certificates for development
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
