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
            let items = voice.cheatGroups.flatMap { $0.items }
            let rows = max(1, (items.count + cols - 1) / cols)
            let spacing: CGFloat = big ? 5 : 3
            let pad: CGFloat = 8
            // Size each row to fill the available height. Cap it so the iPad's tall
            // screen doesn't blow rows up to absurd heights (it centers instead).
            let avail = geo.size.height - pad * 2 - spacing * CGFloat(rows - 1)
            let rowH = min(big ? 48 : 40, max(16, avail / CGFloat(rows)))
            let fontSize = max(8, min(big ? 16 : 13, rowH * 0.42))
            let grid = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)
            ScrollView {
                if items.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    LazyVGrid(columns: grid, spacing: spacing) {
                        ForEach(items) { item in cheatCell(item, fontSize: fontSize, height: rowH) }
                    }
                    .padding(pad)
                    // Center the whole grid in the viewport: on iPhone the rows are
                    // sized to fill it exactly; on iPad they're capped, so the block
                    // floats centered with balanced margins top and bottom.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
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

    /// One-line two-tone chip: spoken phrase (bold yellow on black) | output (white on blue).
    /// Rows are sized by the caller so the whole grid fills the screen.
    private func cheatCell(_ item: CheatItem, fontSize: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(item.say)
                .fontWeight(.bold)
                .foregroundStyle(.yellow)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .background(Color.black)
            Text(item.out)
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 5)
                .background(Color.blue)
        }
        .font(.system(size: fontSize))
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
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
