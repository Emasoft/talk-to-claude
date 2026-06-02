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
        ZStack {
            Self.purpleGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                cheatSheet
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
        // Fixed dark-glass appearance regardless of the device's light/dark setting.
        .preferredColorScheme(.dark)
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

    // Fixed purple gradient + desaturated glass palette (identical in light & dark).
    static let purpleGradient = LinearGradient(
        colors: [Color(red: 0.17, green: 0.10, blue: 0.32),
                 Color(red: 0.40, green: 0.20, blue: 0.60),
                 Color(red: 0.24, green: 0.12, blue: 0.42)],
        startPoint: .top, endPoint: .bottom)
    static let glassYellow = Color(hue: 0.13, saturation: 0.55, brightness: 1.0)
    static let glassBlue = Color(hue: 0.58, saturation: 0.50, brightness: 0.92)
    static let glassRed = Color(hue: 0.99, saturation: 0.55, brightness: 0.88)

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
            let font: CGFloat = big ? 19 : 13
            let pairW: CGFloat = big ? 320 : 184
            ScrollView {
                if all.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    // On the iPad there's room to snap chips to a 6-column grid so
                    // rows line up vertically (left-tabbed). On the narrow iPhone the
                    // full-length names don't leave room for that, so we tight-pack
                    // (columns: 0) to keep everything on one screen.
                    FlowLayout(spacing: big ? 6 : 4, columns: big ? 6 : 0) {
                        ForEach(singles) { singleCell($0, fontSize: font) }
                        ForEach(pairs) { pairCell($0, fontSize: font, width: pairW) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
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

    /// One-line glass chip: spoken phrase (soft yellow) + output (desaturated-blue tag).
    private func singleCell(_ item: CheatItem, fontSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(item.say)
                .fontWeight(.semibold).foregroundStyle(Self.glassYellow)
            Text(item.out)
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Self.glassBlue.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.system(size: fontSize))
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
    }

    /// A START/STOP mode as one fixed-width two-row glass cell: START on top
    /// (blue output tag), STOP below (red output tag) — the toggle reads as a unit.
    private func pairCell(_ p: ModePair, fontSize: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            pairRow(say: p.start.say, out: p.start.out, outColor: Self.glassBlue, fontSize: fontSize)
            pairRow(say: p.stop.say, out: p.stop.out, outColor: Self.glassRed, fontSize: fontSize)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    private func pairRow(say: String, out: String, outColor: Color, fontSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(say.uppercased())
                .fontWeight(.semibold).foregroundStyle(Self.glassYellow)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(out)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(outColor.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
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
        .background(.ultraThinMaterial)
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

/// Wrapping layout for the cheat-sheet chips. Each subview keeps its natural width.
/// With `columns > 0` the chip left-edges snap to an N-column grid so successive rows
/// line up vertically (left-tabbed); a chip wider than one column simply spans more
/// columns. With `columns == 0` it falls back to a tight wrap (pure left-packing).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var columns: Int = 0

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
        var y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0

        if columns > 0 && maxWidth.isFinite {
            // Column-snapped: a slot is 1/N of the width; chips occupy whole slots.
            let slotW = (maxWidth + spacing) / CGFloat(columns)
            var col = 0
            for (i, sv) in subviews.enumerated() {
                let s = sv.sizeThatFits(.unspecified)
                let span = min(columns, max(1, Int(ceil((s.width + spacing) / slotW))))
                if col + span > columns { col = 0; y += rowH + spacing; rowH = 0 }
                spots.append((i, CGFloat(col) * slotW, y, s))
                col += span
                rowH = max(rowH, s.height)
            }
            return (maxWidth, y + rowH, spots)
        }

        // Tight wrap: pack chips left-to-right, wrapping when out of room.
        var x: CGFloat = 0
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
