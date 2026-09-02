import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var claude: ClaudeClient
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var showCommandTest = false
    @State private var showInstall = false

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
                    Button {
                        showInstall = true
                    } label: {
                        Label("Install the ASR for free on your Mac", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("Mac server")
                } footer: {
                    Text("One command sets up the free, open-source speech server on your Mac — it's free now and always.")
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
                        Slider(value: $settings.pauseThreshold, in: 0.4...5.0, step: 0.1)
                    }
                    Toggle("Auto-send each sentence", isOn: $settings.autoSend)
                    Toggle("Require “command” prefix", isOn: $settings.prefixMode)
                    NavigationLink {
                        PrefixGrammarHelpView()
                    } label: {
                        Label("Command grammar", systemImage: "text.book.closed")
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(settings.prefixMode
                            ? "Prefix ON: everything is typed literally — a command fires only when you say “command” first (e.g. “command enter”). Wrap many with “command start … command stop”. See Command grammar above."
                            : "Prefix OFF (default): command words convert automatically (“slash” → /, “enter” → ⏎). Faster for symbols, but common words can get caught.")
                        Text("Every transcription is automatically cleaned up on-device (mis-heard technical terms, homophones) as part of the pipeline. All settings apply live to the running mic.")
                    }
                }

                Section {
                    // Full-screen cover (not a pushed page) so a tap outside / swipe can't
                    // interrupt a running test — the only exit is the test's own Close button.
                    Button {
                        showCommandTest = true
                    } label: {
                        Label("Command self-test", systemImage: "waveform.badge.mic")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Read a fixed phrase aloud; see exactly what the model heard and whether the command was recognized. Nothing is sent to Claude.")
                }

                Section {
                    Text("Your voice is streamed to the Mac over Tailscale's encrypted tunnel and transcribed there by a local AI model (Parakeet), optionally cleaned up by a local LLM — nothing leaves your network. The Mac detects speech pauses automatically, so just talk; no need to tap send.")
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
            .fullScreenCover(isPresented: $showCommandTest) {
                NavigationStack { CommandTestView(settings: settings) }
            }
            .sheet(isPresented: $showInstall) { InstallServerView() }
        }
    }
}
