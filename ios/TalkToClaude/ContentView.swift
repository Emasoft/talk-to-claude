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

    // MARK: - Cheat sheet (variable-width chips that wrap; START/STOP modes paired)

    private var cheatSheet: some View {
        GeometryReader { geo in
            let big = geo.size.width >= 980
            let all = voice.cheatGroups.flatMap { $0.items }
            let singles = all.filter { $0.pair == nil }
            let pairs = modePairs(from: all)
            let font: CGFloat = big ? 22 : 15
            let pairW: CGFloat = big ? 300 : 174
            ScrollView {
                if all.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    // Each chip keeps its own content width; FlowLayout wraps rows.
                    // The two mode toggles are appended last as taller two-row cells.
                    FlowLayout(spacing: big ? 5 : 4) {
                        ForEach(singles) { singleCell($0, fontSize: font) }
                        ForEach(pairs) { pairCell($0, fontSize: font, width: pairW) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                }
            }
        }
    }

    /// Collapse the START/STOP rules sharing a `pair` into ordered pairs (start, stop).
    private func modePairs(from items: [CheatItem]) -> [ModePair] {
        var byName: [String: (start: CheatItem?, stop: CheatItem?)] = [:]
        var order: [String] = []
        for it in items {
            guard let p = it.pair else { continue }
            if byName[p] == nil { byName[p] = (nil, nil); order.append(p) }
            if it.role == "stop" { byName[p]?.stop = it } else { byName[p]?.start = it }
        }
        return order.compactMap { name in
            guard let e = byName[name], let s = e.start, let t = e.stop else { return nil }
            return ModePair(id: name, start: s, stop: t)
        }
    }

    /// One-line two-tone chip: spoken phrase (bold yellow on black) | output (white on blue).
    private func singleCell(_ item: CheatItem, fontSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(item.say)
                .fontWeight(.bold).foregroundStyle(.yellow)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Color.black)
            Text(item.out)
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Color.blue)
        }
        .font(.system(size: fontSize))
        .lineLimit(1)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// A START/STOP mode as one fixed-width two-row cell: START on top (blue output),
    /// STOP below (red output) — so the toggle reads as a single unit.
    private func pairCell(_ p: ModePair, fontSize: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 1) {
            pairRow(say: p.start.say, out: p.start.out, outColor: .blue, fontSize: fontSize)
            pairRow(say: p.stop.say, out: p.stop.out, outColor: .red, fontSize: fontSize)
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func pairRow(say: String, out: String, outColor: Color, fontSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(say.uppercased())
                .fontWeight(.bold).foregroundStyle(.yellow)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Color.black)
            Text(out)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(outColor)
        }
        .font(.system(size: fontSize))
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
                // Two transcript lines: the previous utterance (dim) above the latest.
                Text(voice.finals.count > 1 ? voice.finals[1] : " ")
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
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

/// A START/STOP mode toggle, assembled from the two `pair`-tagged cheat items.
struct ModePair: Identifiable {
    let id: String
    let start: CheatItem
    let stop: CheatItem
}

/// Wrapping layout: every subview keeps its natural width; rows wrap when they run
/// out of horizontal space. This gives the cheat sheet variable-width chips instead
/// of forcing every cell to an equal column width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let r = arrange(maxWidth: maxW, subviews: subviews)
        return CGSize(width: maxW.isFinite ? maxW : r.width, height: r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let r = arrange(maxWidth: bounds.width, subviews: subviews)
        for spot in r.spots {
            subviews[spot.index].place(
                at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y),
                anchor: .topLeading, proposal: ProposedViewSize(spot.size))
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews)
        -> (width: CGFloat, height: CGFloat, spots: [(index: Int, x: CGFloat, y: CGFloat, size: CGSize)]) {
        var spots: [(index: Int, x: CGFloat, y: CGFloat, size: CGSize)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += rowH + spacing; rowH = 0 }
            spots.append((i, x, y, s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return (widest, y + rowH, spots)
    }
}
