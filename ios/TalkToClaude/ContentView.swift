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
    @Environment(\.horizontalSizeClass) private var hSize

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _voice = StateObject(wrappedValue: VoiceStream(settings: s))
        _claude = StateObject(wrappedValue: ClaudeClient(settings: s))
    }

    var body: some View {
        VStack(spacing: 0) {
            cheatSheet
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, claude: claude) }
        .sheet(isPresented: $showSearch) { CheatSheetView(groups: voice.cheatGroups) }
        .onAppear { AVAudioApplication.requestRecordPermission { _ in } }
        .onChange(of: scenePhase) { _, phase in
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

    // MARK: - Cheat sheet (fills the screen)

    private var cheatSheet: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size.width)
            let big = geo.size.width >= 980
            let grid = Array(repeating: GridItem(.flexible(), spacing: 4), count: cols)
            ScrollView {
                if voice.cheatGroups.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(voice.cheatGroups) { group in
                            Text(group.group.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            LazyVGrid(columns: grid, spacing: 4) {
                                ForEach(group.items) { item in cheatCell(item, big: big) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// 6 columns wide (full-screen iPad/landscape), 3 narrow (iPhone / Split View).
    private func columnCount(for width: CGFloat) -> Int {
        if width >= 980 { return 6 }
        if width >= 680 { return 4 }
        return 3
    }

    private func cheatCell(_ item: CheatItem, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.triggers.first ?? item.label)
                .font(.system(size: big ? 13 : 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(item.label)
                .font(.system(size: big ? 12 : 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: big ? 38 : 30, alignment: .leading)
        .padding(.horizontal, big ? 8 : 5).padding(.vertical, big ? 5 : 3)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Compact bottom control bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: toggleMic) {
                ZStack {
                    Circle()
                        .fill(voice.listening ? (voice.speaking ? Color.red : Color.orange) : Color.accentColor)
                        .frame(width: 46, height: 46)
                    Image(systemName: voice.listening ? "waveform" : "mic.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .symbolEffect(.variableColor, isActive: voice.speaking)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(voice.connected ? .green : .gray).frame(width: 8, height: 8)
                    Text(voice.connected ? "Connected" : (voice.listening ? voice.status : "Tap to talk"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if voice.capsMode == "upper" { modeBadge("CAPS", .orange) }
                    if voice.capsMode == "lower" { modeBadge("abc", .blue) }
                    if voice.spellMode { modeBadge("SPELL", .purple) }
                }
                Text(voice.finals.first ?? "—")
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .padding(.leading, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func modeBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

#Preview {
    ContentView()
}
