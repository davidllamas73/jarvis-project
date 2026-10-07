import SwiftUI

/// macOS shell: chat history sidebar + chat detail. Cmd+N new chat,
/// Cmd+Shift+J voice mode, Cmd+. stop speaking, Esc stops generating.
struct MacRootView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var voice: VoiceController

    var body: some View {
        NavigationSplitView {
            ConversationListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .toolbar {
                    ToolbarItem {
                        Button {
                            store.newConversation()
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        .help("New chat (⌘N)")
                    }
                }
        } detail: {
            ChatScreen(onStartVoice: voice.open)
                .navigationTitle(store.selected?.title ?? "Jarvis")
                .toolbar {
                    ToolbarItem(placement: .status) {
                        ConnectionLabel()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if store.isSpeaking {
                            Button {
                                store.stopSpeaking()
                            } label: {
                                Label("Stop speaking", systemImage: "speaker.slash")
                            }
                            .help("Stop speaking (⌘.)")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            voice.open()
                        } label: {
                            Label("Voice mode", systemImage: "waveform")
                        }
                        .help("Voice mode (⇧⌘J)")
                    }
                }
        }
        .sheet(isPresented: $voice.isPresented, onDismiss: {
            if voice.phase != .idle { voice.end() }
        }) {
            VoiceModeView()
                .environmentObject(store)
                .environmentObject(voice)
        }
        .task {
            await store.refreshConnection()
            voice.startWakeWord()
        }
    }
}
