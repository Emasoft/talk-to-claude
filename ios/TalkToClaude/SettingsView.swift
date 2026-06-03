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

                Section("Target session") {
                    if claude.sessions.isEmpty {
                        TextField("tmux session name", text: $settings.session)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Picker("Session", selection: $settings.session) {
                            ForEach(claude.sessions, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                    Button("Load tmux sessions") {
                        Task { await claude.loadSessions() }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pause to end a sentence: \(settings.pauseThreshold, specifier: "%.1f") s")
                        Slider(value: $settings.pauseThreshold, in: 0.4...2.0, step: 0.1)
                    }
                    Toggle("Auto-send each sentence", isOn: $settings.autoSend)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Changes apply the next time you tap the mic.")
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
