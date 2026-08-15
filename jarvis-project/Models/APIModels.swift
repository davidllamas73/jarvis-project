import Foundation

// MARK: - Authentication Models

struct PairDeviceRequest: Codable {
    let deviceName: String
    let deviceType: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case deviceType = "device_type"
    }
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

// MARK: - Search Models

struct SearchRequest: Codable {
    let query: String
    let nResults: Int
    let filterType: String?

    enum CodingKeys: String, CodingKey {
        case query
        case nResults = "n_results"
        case filterType = "filter_type"
    }
}

struct SearchResult: Codable, Identifiable {
    let id: String
    let content: String
    let metadata: [String: AnyCodable]
    let score: Double
}

struct SearchResponse: Codable {
    let results: [SearchResult]
    let query: String
    let total: Int
}

// MARK: - Chat Models

struct ChatRequest: Codable {
    let query: String
    let contextSize: Int
    let conversationId: String?

    enum CodingKeys: String, CodingKey {
        case query
        case contextSize = "context_size"
        case conversationId = "conversation_id"
    }
}

struct ChatResponse: Codable {
    let answer: String
    let sources: [SearchResult]
    let confidence: Double
}

// MARK: - Interview Brief Models

struct InterviewBriefRequest: Codable {
    let company: String
    let person: String?
    let role: String
}

struct InterviewBrief: Codable {
    let companyOverview: String
    let personBackground: String?
    let roleContext: String
    let yourAchievements: [String]
    let talkingPoints: [String]
    let questionsToAsk: [String]
    let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case companyOverview = "company_overview"
        case personBackground = "person_background"
        case roleContext = "role_context"
        case yourAchievements = "your_achievements"
        case talkingPoints = "talking_points"
        case questionsToAsk = "questions_to_ask"
        case generatedAt = "generated_at"
    }
}

// MARK: - Email Draft Models

struct EmailDraftRequest: Codable {
    let recipient: String
    let purpose: String
    let context: String?
}

struct EmailDraft: Codable {
    let subject: String
    let body: String
    let recipient: String
    let purpose: String
}

// MARK: - Voice Models

struct TranscribeRequest: Codable {
    let audioBase64: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case language
    }
}

struct TranscribeResponse: Codable {
    let text: String
    let confidence: Double
}

struct SynthesizeRequest: Codable {
    let text: String
    let voiceId: String?

    enum CodingKeys: String, CodingKey {
        case text
        case voiceId = "voice_id"
    }
}

struct SynthesizeResponse: Codable {
    let audioBase64: String

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
    }
}

// MARK: - System Models

struct HealthResponse: Codable {
    let status: String
    let version: String
    let jarvisStatus: String
    let chromaDocuments: Int
    let chromaChunks: Int

    enum CodingKeys: String, CodingKey {
        case status
        case version
        case jarvisStatus = "jarvis_status"
        case chromaDocuments = "chroma_documents"
        case chromaChunks = "chroma_chunks"
    }
}

// MARK: - Helper for Dynamic JSON

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        default:
            try container.encodeNil()
        }
    }
}
// MARK: - Code Execution Models
struct CodeExecuteRequest: Codable {
    let query: String
    let sessionId: String
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case sessionId = "session_id"
        case maxTokens = "max_tokens"
    }
}

struct ToolCall: Codable {
    let tool: String
    let input: [String: AnyCodable]
    let output: String?
}

struct CodeExecuteResponse: Codable {
    let answer: String
    let toolCalls: [ToolCall]
    let filesModified: [String]
    let executionTimeMs: Int

    enum CodingKeys: String, CodingKey {
        case answer
        case toolCalls = "tool_calls"
        case filesModified = "files_modified"
        case executionTimeMs = "execution_time_ms"
    }
}
