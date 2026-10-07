import SwiftUI
import UIKit

/// iOS shell: chat is home, chat history slides in from the left (ChatGPT-style drawer).
/// Nav bar: drawer button, title + connection status, new chat.
struct IOSRootView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var voice: VoiceController
    @Environment(\.scenePhase) private var scenePhase

    @State private var drawerOpen = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                NavigationStack {
                    ChatScreen(onStartVoice: voice.open)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { chatToolbar }
                }

                if drawerOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { setDrawer(false) }
                        .transition(.opacity)
                        .accessibilityHidden(true)

                    drawer
                        .frame(width: min(330, geo.size.width * 0.86))
                        .transition(.move(edge: .leading))
                        .gesture(
                            DragGesture(minimumDistance: 20).onEnded { value in
                                if value.translation.width < -60 { setDrawer(false) }
                            }
                        )
                }
            }
            .animation(.snappy(duration: 0.28), value: drawerOpen)
        }
        .fullScreenCover(isPresented: $voice.isPresented, onDismiss: {
            if voice.phase != .idle { voice.end() }
        }) {
            VoiceModeView()
                .environmentObject(store)
                .environmentObject(voice)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                JarvisSettingsView()
            }
            .environmentObject(store)
            .environmentObject(voice)
        }
        .task {
            await store.refreshConnection()
            // Let the audio route settle before the first mic grab (real-device race,
            // see the note in the old ContentView).
            try? await Task.sleep(nanoseconds: 500_000_000)
            voice.startWakeWord()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                voice.startWakeWord()
                Task { await store.refreshConnection() }
            case .background:
                // iOS won't let third-party apps keep the mic for a custom wake phrase.
                if voice.isPresented { voice.end() }
                voice.stopWakeWord()
                AudioSessionManager.shared.forceDisable()
            default:
                break
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                setDrawer(true)
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Show chats")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(store.selected?.title ?? "Jarvis")
                    .font(.headline)
                    .lineLimit(1)
                ConnectionLabel()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if store.isSpeaking {
                Button {
                    store.stopSpeaking()
                } label: {
                    Image(systemName: "speaker.slash")
                }
                .accessibilityLabel("Stop speaking")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                store.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New chat")
        }
    }

    // MARK: - Drawer

    private var drawer: some View {
        NavigationStack {
            ConversationListView(onSelect: { setDrawer(false) })
                .navigationTitle("Chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            setDrawer(false)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close chats")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.newConversation()
                            setDrawer(false)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New chat")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        setDrawer(false)
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .buttonStyle(.plain)
                    .background(.bar)
                }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func setDrawer(_ open: Bool) {
        if open {
            // Drop the keyboard first so the drawer isn't fighting it.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        drawerOpen = open
    }
}
