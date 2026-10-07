import SwiftUI
import Foundation

/// One turn in the transcript. User turns are right-aligned bubbles; Jarvis turns
/// are full-width text (no bubble) with tool steps above and actions below,
/// matching the ChatGPT / Claude app pattern.
struct MessageRowView: View {
    let message: JarvisMessage
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        }
    }

    // MARK: - User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentNames.isEmpty {
                    ForEach(message.attachmentNames, id: \.self) { name in
                        Label(name, systemImage: "doc")
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if message.viaVoice {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Spoken")
                    }
                    Text(message.text)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
        }
    }

    // MARK: - Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.steps.isEmpty {
                AgentStepsView(steps: message.steps)
            }

            if message.status == .streaming && message.text.isEmpty {
                ThinkingIndicator()
            } else if !message.text.isEmpty {
                MarkdownText(text: message.text)
            }

            if message.status == .failed {
                failureRow
            } else if message.status == .cancelled && message.text.isEmpty {
                Text("Stopped")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if message.status != .streaming && !message.text.isEmpty {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !message.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
                Button(isSpeakingThis ? "Stop reading" : "Read aloud",
                       systemImage: isSpeakingThis ? "stop.fill" : "speaker.wave.2") {
                    store.readAloud(message.id)
                }
            }
            Button("Retry", systemImage: "arrow.clockwise") { store.retry(message.id) }
        }
    }

    private var failureRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message.errorText ?? "Something went wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Retry") { store.retry(message.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isSpeakingThis: Bool { store.speakingMessageID == message.id }

    private var actionBar: some View {
        HStack(spacing: 4) {
            CopyButton(text: message.text)

            Button {
                store.readAloud(message.id)
            } label: {
                Image(systemName: isSpeakingThis ? "stop.circle" : "speaker.wave.2")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isSpeakingThis ? "Stop reading" : "Read aloud")

            Button {
                store.retry(message.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Retry")

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Pieces

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}

struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Collapsible "what Jarvis did" row: "Used 2 tools" → list of steps.
struct AgentStepsView: View {
    let steps: [AgentStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption2.weight(.semibold))
                    Text(summary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(step.label, systemImage: step.icon)
                                .font(.footnote.weight(.medium))
                            if let output = step.output, !output.isEmpty {
                                Text(output)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    private var summary: String {
        var unique: [String] = []
        for label in steps.map(\.label) where !unique.contains(label) { unique.append(label) }
        if unique.count == 1 { return unique[0] }
        return "Used \(steps.count) tools · " + unique.prefix(2).joined(separator: ", ")
    }
}
