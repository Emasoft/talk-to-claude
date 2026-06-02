import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var settings: AppSettings
    @StateObject private var voice: VoiceStream
    @StateObject private var claude: ClaudeClient
    @State private var audio = AudioStreamer()
    @State private var showSettings = false
    @State private var showSearch = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _voice = StateObject(wrappedValue: VoiceStream(settings: s))
        _claude = StateObject(wrappedValue: ClaudeClient(settings: s))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                statusBar
                micRow
                if let last = voice.finals.first {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                cheatSheet
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .navigationTitle("Talk to Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(settings: settings, claude: claude) }
            .sheet(isPresented: $showSearch) { CheatSheetView(groups: voice.cheatGroups) }
        }
        .onAppear {
            AVAudioApplication.requestRecordPermission { _ in }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground-only: release mic/session when backgrounded so other apps
            // immediately regain audio.
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

    // MARK: - Top bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(voice.connected ? .green : .gray)
                .frame(width: 9, height: 9)
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

    private var micRow: some View {
        HStack(spacing: 14) {
            Button(action: toggleMic) {
                ZStack {
                    Circle()
                        .fill(voice.listening ? (voice.speaking ? Color.red : Color.orange) : Color.accentColor)
                        .frame(width: 60, height: 60)
                        .shadow(radius: voice.listening ? 8 : 3)
                    Image(systemName: voice.listening ? "waveform" : "mic.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .symbolEffect(.variableColor, isActive: voice.speaking)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.status).font(.subheadline)
                if !voice.lastError.isEmpty {
                    Text(voice.lastError).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else if voice.listening {
                    Text("Keep the app in front (use Split View next to other apps).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Always-visible cheat sheet

    private var cheatSheet: some View {
        GeometryReader { geo in
            let cols = geo.size.width >= 700 ? 6 : 3
            let grid = Array(repeating: GridItem(.flexible(), spacing: 4), count: cols)
            ScrollView {
                if voice.cheatGroups.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(voice.cheatGroups) { group in
                            Text(group.group.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            LazyVGrid(columns: grid, spacing: 4) {
                                ForEach(group.items) { item in cheatCell(item) }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func cheatCell(_ item: CheatItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.triggers.first ?? item.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(item.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    ContentView()
}
