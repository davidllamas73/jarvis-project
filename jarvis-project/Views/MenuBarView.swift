import SwiftUI

struct MenuBarView: View {
    @StateObject private var voiceService = VoiceService()
    @StateObject private var apiClient = JarvisAPIClient.shared
    @State private var showMainWindow = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with status
            MenuBarHeader(
                connectionStatus: apiClient.connectionStatus,
                voiceStatus: voiceService.currentStatus
            )

            Divider()

            // Quick voice button
            VoiceQuickButton(voiceService: voiceService)
                .padding(.vertical, 16)

            Divider()

            // Quick actions
            MenuBarActions(
                showMainWindow: $showMainWindow,
                showSettings: $showSettings
            )
        }
        .frame(width: 280)
        .sheet(isPresented: $showMainWindow) {
            ContentView()
                .frame(minWidth: 600, minHeight: 500)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

// MARK: - Header

struct MenuBarHeader: View {
    let connectionStatus: JarvisAPIClient.ConnectionStatus
    let voiceStatus: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundColor(.blue)

                Text("Jarvis")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            if voiceStatus != "Ready" {
                Text(voiceStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
}

// MARK: - Quick Voice Button

struct VoiceQuickButton: View {
    @ObservedObject var voiceService: VoiceService

    var body: some View {
        VStack(spacing: 12) {
            Button(action: handleVoiceButton) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: buttonColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

                    if voiceService.isRecording {
                        VStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.system(size: 28))
                                .foregroundColor(.white)

                            Text(formattedDuration)
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    } else if voiceService.isPlaying {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(voiceService.isProcessing && !voiceService.isRecording)

            Text(buttonText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttonColors: [Color] {
        if voiceService.isRecording {
            return [.red, .orange]
        } else if voiceService.isPlaying {
            return [.blue, .purple]
        } else {
            return [.blue, .cyan]
        }
    }

    private var buttonText: String {
        if voiceService.isRecording {
            return "Tap to stop"
        } else if voiceService.isPlaying {
            return "Speaking..."
        } else {
            return "Talk to Jarvis"
        }
    }

    private var formattedDuration: String {
        let duration = voiceService.recordingDuration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func handleVoiceButton() {
        Task {
            if voiceService.isRecording {
                _ = try? await voiceService.stopRecordingAndProcess()
            } else {
                try? await voiceService.startRecording()
            }
        }
    }
}

// MARK: - Menu Bar Actions

struct MenuBarActions: View {
    @Binding var showMainWindow: Bool
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            MenuBarButton(
                icon: "magnifyingglass",
                title: "Search",
                action: { showMainWindow = true }
            )

            MenuBarButton(
                icon: "message",
                title: "Chat",
                action: { showMainWindow = true }
            )

            MenuBarButton(
                icon: "person.2",
                title: "Interview Prep",
                action: { showMainWindow = true }
            )

            MenuBarButton(
                icon: "envelope",
                title: "Draft Email",
                action: { showMainWindow = true }
            )

            Divider()

            MenuBarButton(
                icon: "gear",
                title: "Settings",
                action: { showSettings = true }
            )

            MenuBarButton(
                icon: "arrow.right.circle",
                title: "Quit Jarvis",
                action: { NSApplication.shared.terminate(nil) },
                color: .red
            )
        }
    }
}

struct MenuBarButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var color: Color = .primary

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                    .frame(width: 20)

                Text(title)
                    .font(.body)
                    .foregroundColor(color)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.accentColor.opacity(0.0)
        )
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var apiClient = JarvisAPIClient.shared
    @State private var apiURL: String = "https://localhost:8443/api/v1"

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Settings content
            Form {
                Section("Connection") {
                    TextField("API URL", text: $apiURL)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Status:")
                            .foregroundColor(.secondary)

                        Spacer()

                        switch apiClient.connectionStatus {
                        case .connected:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        case .connecting:
                            Label("Connecting", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.yellow)
                        case .disconnected:
                            Label("Disconnected", systemImage: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        case .error(let message):
                            Label("Error", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .help(message)
                        }
                    }

                    Button("Test Connection") {
                        Task {
                            try? await apiClient.checkHealth()
                        }
                    }
                }

                Section("Authentication") {
                    HStack {
                        Text("Status:")
                            .foregroundColor(.secondary)

                        Spacer()

                        if apiClient.isAuthenticated {
                            Label("Authenticated", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Not Authenticated", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    if apiClient.isAuthenticated {
                        Button("Clear Tokens") {
                            apiClient.clearTokens()
                        }
                    } else {
                        Button("Pair Device") {
                            Task {
                                try? await apiClient.pairDevice()
                            }
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("1.0.0")
                    }

                    HStack {
                        Text("Build")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("2026.08.07")
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Spacer()
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Preview

#Preview {
    MenuBarView()
}
