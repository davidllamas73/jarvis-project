import Foundation

/// One chat thread. Persisted locally as JSON by ConversationPersistence.
/// `id` doubles as the backend session_id so the server keeps context per thread.
struct JarvisConversation: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = "New chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [JarvisMessage] = []

    /// Title comes from the first user message until the user renames it.
    var hasCustomTitle = false
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

enum MessageStatus: String, Codable {
    case streaming
    case complete
    case failed
    case cancelled
}

/// A tool the agent ran while answering, e.g. search_brain_archive.
struct AgentStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: String
    var output: String?

    /// Human label for the raw tool name.
    var label: String {
        switch tool {
        case "search_knowledge_base": return "Searched wiki"
        case "search_brain_archive": return "Searched brain archive"
        case "find_documents": return "Found documents"
        case "extract_from_pdf": return "Read PDF"
        case "search_web": return "Searched the web"
        case "execute_python": return "Ran Python"
        case "execute_shell": return "Ran shell command"
        case "read_file": return "Read file"
        case "write_file": return "Wrote file"
        case "schedule_background_task": return "Scheduled background task"
        case "update_wiki_entity": return "Updated wiki"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var icon: String {
        switch tool {
        case "search_web": return "globe"
        case "execute_python", "execute_shell": return "terminal"
        case "read_file", "write_file", "find_documents", "extract_from_pdf": return "doc.text"
        case "schedule_background_task": return "clock"
        default: return "magnifyingglass"
        }
    }
}

struct JarvisMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: MessageRole
    var text: String
    var createdAt = Date()
    var status: MessageStatus = .complete
    var errorText: String?
    var steps: [AgentStep] = []
    var attachmentNames: [String] = []
    /// True when the turn came from voice mode. Used for the mic glyph on user bubbles.
    var viaVoice = false
}
