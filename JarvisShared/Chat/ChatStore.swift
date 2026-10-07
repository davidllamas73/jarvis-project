import Foundation
import Combine
import SwiftUI

/// Single source of truth for chat on both iOS and macOS.
///
/// The key rule that fixes the old "can't send a new prompt" lock: generation
/// (network stream) and speech (TTS playback) are tracked separately. The
/// composer only cares about `isGenerating`, which clears the moment the stream
/// ends. Speech can keep playing; sending a new message just cuts it off.
@MainActor
final class ChatStore: ObservableObject {
    enum Connection: Equatable {
        case unknown
        case online(chunks: Int)
        case offline
    }

    @Published private(set) var conversations: [JarvisConversation] = []
    @Published var selectedID: String?
    @Published private(set) var generatingMessageID: UUID?
    @Published private(set) var speakingMessageID: UUID?
    @Published private(set) var connection: Connection = .unknown

    /// Called when a spoken answer finishes playing on its own (not when stopped).
    /// VoiceController uses it to start listening for the next turn.
    var onSpeechFinished: ((UUID) -> Void)?

    let tts: NativeTTSManager
    private let api = JarvisAPIClient.shared
    private var generationTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?

    init(tts: NativeTTSManager = NativeTTSManager()) {
        self.tts = tts
        self.conversations = ConversationPersistence.load()
            .sorted { $0.updatedAt > $1.updatedAt }
        self.selectedID = conversations.first?.id
    }

    // MARK: - Derived state

    var isGenerating: Bool { generatingMessageID != nil }
    var isSpeaking: Bool { speakingMessageID != nil }

    var selected: JarvisConversation? {
        guard let selectedID else { return nil }
        return conversations.first { $0.id == selectedID }
    }

    // MARK: - Conversations

    func newConversation() {
        // Reuse an existing empty chat instead of piling up blanks.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selectedID = empty.id
            return
        }
        let convo = JarvisConversation()
        conversations.insert(convo, at: 0)
        selectedID = convo.id
        scheduleSave()
    }

    func select(_ id: String) {
        selectedID = id
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = index(of: id) else { return }
        conversations[idx].title = trimmed
        conversations[idx].hasCustomTitle = true
        scheduleSave()
    }

    func delete(_ id: String) {
        if let idx = index(of: id),
           let genID = generatingMessageID,
           conversations[idx].messages.contains(where: { $0.id == genID }) {
            stopGenerating()
        }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
        scheduleSave()
    }

    // MARK: - Sending

    /// Sends a prompt in the selected conversation (creating one if needed).
    /// Never blocked by speech; if an answer is still streaming, it is stopped first.
    @discardableResult
    func send(_ rawText: String,
              attachments: [PendingAttachment] = [],
              speak: Bool = false,
              viaVoice: Bool = false) -> UUID? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if isGenerating { stopGenerating() }
        stopSpeaking()

        if selected == nil { newConversation() }
        guard let convoID = selectedID, let idx = index(of: convoID) else { return nil }

        var user = JarvisMessage(role: .user, text: text)
        user.attachmentNames = attachments.map(\.filename)
        user.viaVoice = viaVoice
        let assistant = JarvisMessage(role: .assistant, text: "", status: .streaming)

        conversations[idx].messages.append(user)
        conversations[idx].messages.append(assistant)
        conversations[idx].updatedAt = Date()
        if !conversations[idx].hasCustomTitle && conversations[idx].messages.count == 2 {
            conversations[idx].title = Self.makeTitle(from: text)
        }
        moveToTop(convoID)

        generatingMessageID = assistant.id
        let assistantID = assistant.id
        generationTask = Task { [weak self] in
            await self?.runGeneration(conversationID: convoID,
                                      messageID: assistantID,
                                      query: text,
                                      attachments: attachments,
                                      speak: speak)
        }
        scheduleSave()
        return assistantID
    }

    /// Re-asks the user prompt that produced `messageID` (an assistant reply).
    func retry(_ messageID: UUID) {
        guard let convoID = selectedID, let idx = index(of: convoID),
              let msgIdx = conversations[idx].messages.firstIndex(where: { $0.id == messageID }),
              msgIdx > 0,
              conversations[idx].messages[msgIdx - 1].role == .user else { return }

        let prompt = conversations[idx].messages[msgIdx - 1].text
        // Drop the old user+assistant pair; send() appends a fresh one.
        conversations[idx].messages.removeSubrange((msgIdx - 1)...msgIdx)
        send(prompt)
    }

    /// Stops the network stream immediately. UI unlocks right away; the task
    /// cleans up in the background.
    func stopGenerating() {
        guard let genID = generatingMessageID else { return }
        generationTask?.cancel()
        generationTask = nil
        updateMessage(genID) { msg in
            if msg.status == .streaming {
                msg.status = msg.text.isEmpty ? .cancelled : .complete
            }
        }
        generatingMessageID = nil
        stopSpeaking()
        scheduleSave()
    }

    // MARK: - Speech

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        if speakingMessageID != nil || tts.isSpeaking {
            tts.stop()
        }
        speakingMessageID = nil
    }

    func readAloud(_ messageID: UUID) {
        if speakingMessageID == messageID {
            stopSpeaking()
            return
        }
        guard let msg = message(messageID), !msg.text.isEmpty else { return }
        stopSpeaking()
        let (chunks, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(SpeechText.clean(msg.text))
        continuation.finish()
        startSpeech(messageID: messageID, chunks: chunks)
    }

    private func startSpeech(messageID: UUID, chunks: AsyncThrowingStream<String, Error>) {
        speakingMessageID = messageID
        speechTask = Task { [weak self] in
            guard let self else { return }
            try? await self.tts.speakStream(chunks)
            guard !Task.isCancelled, self.speakingMessageID == messageID else { return }
            self.speakingMessageID = nil
            self.onSpeechFinished?(messageID)
        }
    }

    // MARK: - Health

    func refreshConnection() async {
        do {
            let health = try await api.checkHealth()
            connection = .online(chunks: health.chromaChunks)
        } catch {
            connection = .offline
        }
    }

    // MARK: - Generation

    private func runGeneration(conversationID: String,
                               messageID: UUID,
                               query: String,
                               attachments: [PendingAttachment],
                               speak: Bool) async {
        let apiAttachments = attachments.map {
            FileAttachment(filename: $0.filename, contentBase64: $0.base64Content)
        }
        let stream = api.executeCodeStream(query: query,
                                           sessionId: conversationID,
                                           attachments: apiAttachments.isEmpty ? nil : apiAttachments)

        var speechContinuation: AsyncThrowingStream<String, Error>.Continuation?
        if speak {
            let (chunks, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            speechContinuation = continuation
            startSpeech(messageID: messageID, chunks: chunks)
        }
        defer { speechContinuation?.finish() }

        do {
            for try await event in stream {
                guard generatingMessageID == messageID, !Task.isCancelled else { return }
                switch event {
                case .textDelta(let delta):
                    updateMessage(messageID) { $0.text += delta }
                    speechContinuation?.yield(SpeechText.clean(delta))
                case .done(let response):
                    var hadText = true
                    updateMessage(messageID) { msg in
                        // `answer` is authoritative if deltas never arrived (short replies).
                        if msg.text.isEmpty {
                            hadText = false
                            msg.text = response.answer
                        }
                        msg.steps = response.toolCalls.map { AgentStep(tool: $0.tool, output: $0.output) }
                        msg.status = .complete
                    }
                    if !hadText { speechContinuation?.yield(SpeechText.clean(response.answer)) }
                case .error(let message):
                    throw APIError.serverError(message)
                }
            }
            guard generatingMessageID == messageID else { return }
            updateMessage(messageID) { msg in
                if msg.status == .streaming {
                    msg.status = msg.text.isEmpty ? .failed : .complete
                    if msg.text.isEmpty { msg.errorText = "Jarvis didn't return an answer." }
                }
            }
        } catch {
            guard generatingMessageID == messageID, !Task.isCancelled else { return }
            updateMessage(messageID) { msg in
                msg.status = .failed
                msg.errorText = Self.friendly(error)
            }
            if speak { stopSpeaking() }
        }

        if generatingMessageID == messageID { generatingMessageID = nil }
        Task { await refreshConnection() }
        scheduleSave()
    }

    // MARK: - Helpers

    private func index(of id: String) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    func message(_ id: UUID) -> JarvisMessage? {
        for convo in conversations {
            if let msg = convo.messages.first(where: { $0.id == id }) { return msg }
        }
        return nil
    }

    private func updateMessage(_ id: UUID, _ change: (inout JarvisMessage) -> Void) {
        for c in conversations.indices {
            if let m = conversations[c].messages.firstIndex(where: { $0.id == id }) {
                change(&conversations[c].messages[m])
                conversations[c].updatedAt = Date()
                return
            }
        }
    }

    private func moveToTop(_ id: String) {
        guard let idx = index(of: id), idx != 0 else { return }
        let convo = conversations.remove(at: idx)
        conversations.insert(convo, at: 0)
    }

    /// Debounced so streaming deltas don't write the file dozens of times a second.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            ConversationPersistence.save(self.conversations)
        }
    }

    private static func makeTitle(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    private static func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Check your connection and retry."
            case .timedOut:
                return "Jarvis took too long to respond. Retry?"
            case .cannotConnectToHost, .cannotFindHost:
                return "Can't reach the Jarvis server. Is it running?"
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }
        if let apiError = error as? APIError, let description = apiError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// Strips markdown syntax so TTS doesn't read out asterisks and hashes.
enum SpeechText {
    static func clean(_ text: String) -> String {
        var out = text
        for token in ["**", "__", "`", "#", "*", ">"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        return out
    }
}
