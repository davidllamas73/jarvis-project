import SwiftUI

/// Full-screen voice conversation (ChatGPT voice-mode pattern): one big orb you tap,
/// live captions, and an always-visible End button. Turns are written to the chat.
struct VoiceModeView: View {
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 20)

            Button(action: voice.primaryAction) {
                orb
            }
            .buttonStyle(.plain)
            .accessibilityLabel(orbAccessibilityLabel)

            Text(voice.statusText)
                .font(.callout)
                .foregroundStyle(isError ? Color.orange : Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .padding(.horizontal, 24)
                .animation(.default, value: voice.statusText)

            caption
                .padding(.top, 16)
                .padding(.horizontal, 28)

            Spacer(minLength: 20)

            controls
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .background(.background)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(store.selected?.title ?? "Voice")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            ConnectionLabel()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var orb: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(orbColor.opacity(0.18))
                    .frame(width: 220, height: 220)
                    .scaleEffect(haloScale(t))
                Circle()
                    .fill(orbColor.gradient)
                    .frame(width: 160, height: 160)
                    .scaleEffect(coreScale(t))
                Image(systemName: orbIcon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 240, height: 240)
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch voice.phase {
        case .thinking, .speaking:
            if let answer = latestAnswer, !answer.isEmpty {
                Text(answer)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .truncationMode(.head)
            }
        default:
            if !voice.lastHeard.isEmpty {
                Text("\u{201C}\(voice.lastHeard)\u{201D}")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                if voice.phase == .speaking || voice.phase == .thinking {
                    voice.interrupt()
                } else {
                    store.stopSpeaking()
                }
            } label: {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Interrupt")

            Button(action: voice.end) {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .frame(width: 64, height: 64)
                    .background(Color.red.opacity(0.15), in: Circle())
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("End voice mode")
        }
    }

    // MARK: - Derived

    private var latestAnswer: String? {
        guard let messages = store.selected?.messages,
              let last = messages.last, last.role == .assistant else { return nil }
        return last.text
    }

    private var isError: Bool {
        if case .error = voice.phase { return true }
        return false
    }

    private var orbColor: Color {
        switch voice.phase {
        case .listening: return .accentColor
        case .speaking: return .indigo
        case .thinking, .transcribing: return .purple
        case .error: return .orange
        case .idle: return .gray
        }
    }

    private var orbIcon: String {
        switch voice.phase {
        case .listening: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .thinking, .transcribing: return "ellipsis"
        case .error: return "arrow.clockwise"
        case .idle: return "mic.fill"
        }
    }

    private var orbAccessibilityLabel: String {
        switch voice.phase {
        case .listening: return "Send what I said"
        case .speaking, .thinking: return "Interrupt Jarvis"
        default: return "Start listening"
        }
    }

    private func coreScale(_ t: TimeInterval) -> CGFloat {
        switch voice.phase {
        case .listening:
            return 1 + CGFloat(min(max(voice.audioLevel, 0), 1)) * 0.25
        case .speaking:
            return reduceMotion ? 1 : 1 + 0.05 * CGFloat(sin(t * 6))
        case .thinking, .transcribing:
            return reduceMotion ? 1 : 1 + 0.03 * CGFloat(sin(t * 2.5))
        default:
            return 1
        }
    }

    private func haloScale(_ t: TimeInterval) -> CGFloat {
        guard !reduceMotion, voice.phase != .idle else { return 1 }
        return 1 + 0.06 * CGFloat(sin(t * 1.8))
    }
}
