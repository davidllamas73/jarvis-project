import SwiftUI

/// The chat surface shared by iOS and macOS: transcript (or empty state) with the
/// composer pinned to the bottom via safeAreaInset so it rides above the keyboard.
/// Platform shells (iOS drawer, macOS split view) wrap this and add navigation.
struct ChatScreen: View {
    @EnvironmentObject private var store: ChatStore
    @FocusState private var composerFocused: Bool
    @State private var isNearBottom = true
    @State private var scrollToBottomToken = 0

    var onStartVoice: () -> Void

    var body: some View {
        Group {
            if let convo = store.selected, !convo.messages.isEmpty {
                TranscriptView(conversation: convo,
                               isNearBottom: $isNearBottom,
                               scrollToBottomToken: scrollToBottomToken,
                               dismissKeyboard: { composerFocused = false })
            } else {
                EmptyChatView()
                    .onTapGesture { composerFocused = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if !isNearBottom, store.selected?.messages.isEmpty == false {
                    Button {
                        scrollToBottomToken += 1
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                ComposerView(isFocused: $composerFocused, onStartVoice: onStartVoice)
                    .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .animation(.snappy, value: isNearBottom)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composerFocused = false }
            }
        }
        #endif
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let conversation: JarvisConversation
    @Binding var isNearBottom: Bool
    let scrollToBottomToken: Int
    var dismissKeyboard: () -> Void

    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(conversation.messages) { message in
                        MessageRowView(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 80
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            // New turn: always follow, even if the user had scrolled up.
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            // Streaming tokens: follow only if the user is already at the bottom.
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if isNearBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.id) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: scrollToBottomToken) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            #if os(iOS)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            #endif
        }
    }
}

// MARK: - Empty state

struct EmptyChatView: View {
    @EnvironmentObject private var store: ChatStore

    private struct Suggestion: Hashable {
        let icon: String
        let text: String
    }

    private let suggestions: [Suggestion] = [
        Suggestion(icon: "calendar", text: "What's on my plate this week?"),
        Suggestion(icon: "briefcase", text: "Prep me for my next executive interview"),
        Suggestion(icon: "cross.case", text: "Summarise the Phuket longevity clinic opportunity"),
        Suggestion(icon: "chart.line.uptrend.xyaxis", text: "What did I achieve at Central Retail?")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                    Text("How can I help, David?")
                        .font(.title2.weight(.semibold))
                    ConnectionLabel()
                }
                .padding(.top, 60)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            store.send(suggestion.text)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: suggestion.icon)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(suggestion.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 620)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// "Connected · 840 chunks" / "Offline" pill used in headers and the empty state.
struct ConnectionLabel: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch store.connection {
        case .online: return .green
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    private var text: String {
        switch store.connection {
        case .online: return "Connected"
        case .offline: return "Offline"
        case .unknown: return "Connecting…"
        }
    }
}
