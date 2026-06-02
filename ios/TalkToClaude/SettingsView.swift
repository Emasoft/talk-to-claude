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

                Section("Speaking") {
                    Toggle("Auto-send on pause", isOn: $settings.autoSend)
                    if settings.autoSend {
                        VStack(alignment: .leading) {
                            Text("Pause before sending: \(settings.pauseThreshold, specifier: "%.1f")s")
                                .font(.caption)
                            Slider(value: $settings.pauseThreshold, in: 0.5...3.0, step: 0.1)
                        }
                    }
                }

                Section("Display") {
                    Toggle("Show Claude's output", isOn: $settings.showReplies)
                }

                Section {
                    Text("Audio is transcribed on-device and never leaves your phone. Only the resulting text is sent — over Tailscale's encrypted tunnel — to the Mac.")
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
