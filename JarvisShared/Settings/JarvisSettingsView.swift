import SwiftUI

/// Settings shared by both apps. iOS shows it as a sheet; macOS as the Settings scene (Cmd+,).
/// Named JarvisSettingsView to avoid clashing with the legacy SettingsView in archives.
struct JarvisSettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var voice: VoiceController
    @AppStorage("autoSpeakTyped") private var autoSpeakTyped = false
    @AppStorage("autoSpeakVoice") private var autoSpeakVoice = true
    @AppStorage("wakeWordEnabled") private var wakeWordEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Voice") {
                Toggle("Read answers aloud in voice mode", isOn: $autoSpeakVoice)
                Toggle("Read typed answers aloud", isOn: $autoSpeakTyped)
                Toggle("Listen for \u{201C}Hey Jarvis\u{201D}", isOn: $wakeWordEnabled)
                    .onChange(of: wakeWordEnabled) { _, enabled in
                        if enabled { voice.startWakeWord() } else { voice.stopWakeWord() }
                    }
                if wakeWordEnabled {
                    WakeWordStatusRow(wakeWord: voice.wakeWord)
                }
                #if os(iOS)
                Text("The wake word only works while Jarvis is open on screen. iOS doesn't allow apps to listen in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("Server") {
                LabeledContent("Status") { ConnectionLabel() }
                LabeledContent("Endpoint") {
                    Text(JarvisAPIClient.shared.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if case .online(let chunks) = store.connection {
                    LabeledContent("Knowledge base", value: "\(chunks) chunks")
                }
                Button("Check connection") {
                    Task { await store.refreshConnection() }
                }
            }

            Section("History") {
                LabeledContent("Chats", value: "\(store.conversations.count)")
                Button("Delete all chats", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #else
        .frame(width: 460, height: 420)
        #endif
        .confirmationDialog("Delete all chats?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                for convo in store.conversations { store.delete(convo.id) }
            }
        } message: {
            Text("This removes every conversation from this device.")
        }
        .task { await store.refreshConnection() }
    }
}

/// Live wake-word listener state, observed directly so it updates in place.
private struct WakeWordStatusRow: View {
    @ObservedObject var wakeWord: WakeWordManager

    var body: some View {
        LabeledContent("Wake word status") {
            HStack(spacing: 6) {
                Circle()
                    .fill(wakeWord.isListeningForWakeWord ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(wakeWord.statusMessage)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
