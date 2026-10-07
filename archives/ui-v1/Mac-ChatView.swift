import SwiftUI
import Combine

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText = ""
    @State private var isProcessing = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    // Auto-scroll to latest message
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 12) {
                TextField("Ask Jarvis...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                }
                .disabled(inputText.isEmpty || isProcessing)
                .buttonStyle(.plain)
            }
            .padding()
        }
        .navigationTitle("Chat with Jarvis")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { viewModel.clearHistory() }) {
                    Image(systemName: "trash")
                }
                .disabled(viewModel.messages.isEmpty)
            }
        }
    }

    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let query = inputText
        inputText = ""
        isProcessing = true

        Task {
            await viewModel.sendMessage(query)
            isProcessing = false
            isInputFocused = true
        }
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            Circle()
                .fill(message.isUser ? Color.blue : Color.green)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: message.isUser ? "person.fill" : "cpu")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                )

            // Message content
            VStack(alignment: .leading, spacing: 8) {
                // Sender name and timestamp
                HStack {
                    Text(message.isUser ? "You" : "Jarvis")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Message text
                Text(message.content)
                    .textSelection(.enabled)
                    .font(.body)

                // Sources if available
                if !message.sources.isEmpty {
                    SourcesView(sources: message.sources)
                }

                // Confidence indicator
                if !message.isUser, let confidence = message.confidence {
                    ConfidenceIndicator(confidence: confidence)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.isUser ? Color.clear : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Sources View

struct SourcesView: View {
    let sources: [SearchResult]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.caption)
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(.caption)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sources) { source in
                        SourceItem(source: source)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
}

struct SourceItem: View {
    let source: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 6, height: 6)

                if let title = source.metadata["title"]?.value as? String {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Spacer()

                Text(String(format: "%.0f%%", source.score * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(source.content)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .padding(.leading, 14)
        }
    }
}

// MARK: - Confidence Indicator

struct ConfidenceIndicator: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
                .font(.caption2)
                .foregroundColor(confidenceColor)

            Text("Confidence: \(Int(confidence * 100))%")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var confidenceColor: Color {
        if confidence > 0.7 {
            return .green
        } else if confidence > 0.4 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp: Date
    let sources: [SearchResult]
    let confidence: Double?

    init(content: String, isUser: Bool, sources: [SearchResult] = [], confidence: Double? = nil) {
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
        self.sources = sources
        self.confidence = confidence
    }
}

// MARK: - View Model

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []

    private let apiClient = JarvisAPIClient.shared

    func sendMessage(_ query: String) async {
        // Add user message
        let userMessage = ChatMessage(content: query, isUser: true)
        messages.append(userMessage)

        do {
            // Get response from API
            let response = try await apiClient.chat(query: query)

            // Add Jarvis response
            let jarvisMessage = ChatMessage(
                content: response.answer,
                isUser: false,
                sources: response.sources,
                confidence: response.confidence
            )
            messages.append(jarvisMessage)

        } catch {
            // Show error as Jarvis message
            let errorMessage = ChatMessage(
                content: "Sorry, I encountered an error: \(error.localizedDescription)",
                isUser: false
            )
            messages.append(errorMessage)
        }
    }

    func clearHistory() {
        messages.removeAll()
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        ChatView()
    }
}
