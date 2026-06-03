import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var claude: ClaudeClient
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac receiver (Tailscale)") {
                    LabeledContent("IP") {
                        TextField("100.99.233.43", text: $settings.macIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("8765", text: $settings.port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Token") {
                        TextField("shared secret", text: $settings.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        testing = true
                        Task {
                            await claude.checkHealth()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                            else if claude.connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                    if !claude.lastError.isEmpty {
                        Text(claude.lastError).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    if !claude.sessions.isEmpty {
                        Picker("Session", selection: $settings.session) {
                            ForEach(claude.sessions) { s in
                                Text(s.label).tag(s.target)
                            }
                        }
                    }
                    TextField("tmux target (e.g. demo or demo:0.0)", text: $settings.session)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Refresh Claude sessions") {
                        Task { await claude.loadSessions() }
                    }
                } header: {
                    Text("Target session")
                } footer: {
                    Text("Pick the Claude to talk to from the sidebar list (tap the ☰ button). This field is a manual override.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pause to end a sentence: \(settings.pauseThreshold, specifier: "%.1f") s")
                        Slider(value: $settings.pauseThreshold, in: 0.4...2.0, step: 0.1)
                    }
                    Toggle("Auto-send each sentence", isOn: $settings.autoSend)
                    Toggle("Require “command” prefix", isOn: $settings.prefixMode)
                } header: {
                    Text("Voice")
                } footer: {
                    Text(settings.prefixMode
                        ? "ON: everything you say is typed literally — a command fires only when you say “command” first (e.g. “command enter”, “command arrow up”). Say “command symbols … command words” to bracket a path/code burst. No more eaten words.\n\nChanges apply the next time you tap the mic."
                        : "OFF (default): command words convert automatically (“slash” → /, “enter” → ⏎). Faster for symbols, but common words can get caught.\n\nChanges apply the next time you tap the mic.")
                }

                Section {
                    Text("Your voice is streamed to the Mac over Tailscale's encrypted tunnel and transcribed there by a local Whisper model — nothing leaves your network. The Mac detects speech pauses automatically, so just talk; no need to tap send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
