//
//  jarvis_projectApp.swift
//  jarvis-project
//
//  Created by David Llamas on 07/08/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct jarvis_projectApp: App {
    @StateObject private var store: ChatStore
    @StateObject private var voice: VoiceController

    init() {
        let store = ChatStore()
        _store = StateObject(wrappedValue: store)
        _voice = StateObject(wrappedValue: VoiceController(store: store))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MacRootView()
                .environmentObject(store)
                .environmentObject(voice)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newConversation() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Jarvis") {
                Button("Voice Mode") { voice.open() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Stop Generating") { store.stopGenerating() }
                    .disabled(!store.isGenerating)
                Button("Stop Speaking") { store.stopSpeaking() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            JarvisSettingsView()
                .environmentObject(store)
        }

        MenuBarExtra("Jarvis", systemImage: "sparkles") {
            MenuBarQuickActions()
                .environmentObject(store)
                .environmentObject(voice)
        }
        #endif
    }
}

#if os(macOS)
/// Menu bar quick actions. Opens (or focuses) the main window.
private struct MenuBarQuickActions: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var voice: VoiceController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Jarvis") { showMain() }
        Button("New Chat") {
            store.newConversation()
            showMain()
        }
        Button("Voice Mode") {
            showMain()
            voice.open()
        }
        if store.isSpeaking {
            Button("Stop Speaking") { store.stopSpeaking() }
        }
        Divider()
        Button("Quit Jarvis") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMain() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
#endif
