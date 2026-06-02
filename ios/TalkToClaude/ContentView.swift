import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var settings: AppSettings
    @StateObject private var voice: VoiceStream
    @StateObject private var claude: ClaudeClient
    @State private var audio = AudioStreamer()
    @State private var showSettings = false
    @State private var showCheatSheet = false
    @Environment(\.scenePhase) private var scenePhase

    private let paneTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _voice = StateObject(wrappedValue: VoiceStream(settings: s))
        _claude = StateObject(wrappedValue: ClaudeClient(settings: s))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusBar
                micControls
                if !voice.lastError.isEmpty { errorBanner }
                if !voice.finals.isEmpty { sentCard }
                if settings.showReplies { paneCard }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Talk to Claude")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCheatSheet = true } label: { Image(systemName: "list.bullet.rectangle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings, claude: claude)
            }
            .sheet(isPresented: $showCheatSheet) {
                CheatSheetView(groups: voice.cheatGroups)
            }
        }
        .onAppear {
            AVAudioApplication.requestRecordPermission { _ in }
            Task { await claude.checkHealth() }
        }
        .onReceive(paneTimer) { _ in
            guard settings.showReplies, voice.connected else { return }
            Task { await claude.loadPane(session: settings.session) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground-only: release the mic + audio session the moment we leave
            // the foreground so other apps immediately regain audio. (A background
            // mic session keeps every other app interrupted until we're quit.)
            if phase == .background && voice.listening {
                audio.stop()
                voice.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func toggleMic() {
        if voice.listening {
            audio.stop()
            voice.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            audio.onPCM = { [weak voice] data in voice?.sendPCM(data) }
            do {
                try audio.start()
                voice.start(session: settings.session)
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                voice.lastError = "Mic start failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(voice.connected ? .green : .gray)
                .frame(width: 10, height: 10)
            Text(voice.connected ? "Connected" : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
            if voice.capsMode == "upper" { modeBadge("CAPS", .orange) }
            if voice.capsMode == "lower" { modeBadge("abc", .blue) }
            if voice.spellMode { modeBadge("SPELL", .purple) }
            Spacer()
            Text("▸ \(settings.session)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func modeBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var micControls: some View {
        VStack(spacing: 10) {
            Button(action: toggleMic) {
                ZStack {
                    Circle()
                        .fill(voice.listening ? (voice.speaking ? Color.red : Color.orange) : Color.accentColor)
                        .frame(width: 116, height: 116)
                        .shadow(radius: voice.listening ? 14 : 4)
                    Image(systemName: voice.listening ? "waveform" : "mic.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .symbolEffect(.variableColor, isActive: voice.speaking)
            Text(voice.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            if voice.listening {
                Text("Keep this app in front while you talk (on iPad, use Split View next to other apps).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 6)
    }

    private var errorBanner: some View {
        Text(voice.lastError)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sentCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sent to Claude")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(voice.finals.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var paneCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude output ▸ \(settings.session)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(claude.pane.isEmpty ? "(no output yet)" : claude.pane)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.green)
    }
}

#Preview {
    ContentView()
}
