import Foundation

/// Saves all conversations to one JSON file in Application Support.
/// Small enough for a personal assistant; swap for SwiftData if it ever gets large.
enum ConversationPersistence {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    static func load() -> [JarvisConversation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([JarvisConversation].self, from: data)
        } catch {
            print("⚠️ ConversationPersistence: failed to decode, starting fresh: \(error)")
            return []
        }
    }

    static func save(_ conversations: [JarvisConversation]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ ConversationPersistence: save failed: \(error)")
        }
    }
}
