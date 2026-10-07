//
//  JarvisiOSApp.swift
//  JarvisiOS
//
//  Created by David Llamas on 15/08/2026.
//

import SwiftUI

@main
struct JarvisiOSApp: App {
    @StateObject private var store: ChatStore
    @StateObject private var voice: VoiceController

    init() {
        let store = ChatStore()
        _store = StateObject(wrappedValue: store)
        _voice = StateObject(wrappedValue: VoiceController(store: store))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(store)
                .environmentObject(voice)
        }
    }
}
