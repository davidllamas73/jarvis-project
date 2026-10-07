import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Bottom-pinned input. Rules:
/// - Never disabled by speech. Only generation turns Send into Stop.
/// - Empty field + idle shows the mic (voice mode); typing shows Send.
/// - macOS: Return sends, Option+Return newline, Esc stops, Cmd+Return sends.
/// - iOS: Return is a newline; send with the button. Keyboard dismiss lives in ChatScreen.
struct ComposerView: View {
    @EnvironmentObject private var store: ChatStore
    var isFocused: FocusState<Bool>.Binding
    var onStartVoice: () -> Void

    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var showImporter = false
    @State private var sendCount = 0
    @AppStorage("autoSpeakTyped") private var autoSpeakTyped = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                attachmentChips
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Attach files")

                TextField("Ask Jarvis", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused(isFocused)
                    .onSubmit(submit)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Message")

                trailingButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.quaternary))
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true,
                      onCompletion: handleImport)
    }

    // MARK: - Trailing button (mic / send / stop)

    @ViewBuilder
    private var trailingButton: some View {
        if store.isGenerating {
            Button(action: store.stopGenerating) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.primary, in: Circle())
                    .foregroundStyle(.background)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Stop generating")
        } else if trimmed.isEmpty && attachments.isEmpty {
            Button(action: onStartVoice) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start voice mode")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc").font(.caption)
                        Text(attachment.filename).font(.caption).lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func submit() {
        guard !trimmed.isEmpty, !store.isGenerating else { return }
        store.send(trimmed, attachments: attachments, speak: autoSpeakTyped)
        text = ""
        attachments = []
        sendCount += 1
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                attachments.append(PendingAttachment(filename: url.lastPathComponent,
                                                     base64Content: data.base64EncodedString()))
            }
        }
    }
}
