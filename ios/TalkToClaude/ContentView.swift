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
            Self.silkBackground.ignoresSafeArea()
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

    // Fixed blue-silk background + glass-chip palette (identical in light & dark).
    static let silkDark = Color(red: 0.01, green: 0.09, blue: 0.24)   // fold valleys
    static let silkDeep = Color(red: 0.03, green: 0.24, blue: 0.46)
    static let silkAzure = Color(red: 0.08, green: 0.45, blue: 0.72)
    static let silkBright = Color(red: 0.20, green: 0.64, blue: 0.88)
    static let silkHi = Color(red: 0.60, green: 0.85, blue: 1.0)     // specular highlights
    static let glassYellow = Color(hue: 0.13, saturation: 0.55, brightness: 1.0)
    static let chipSay = Color(red: 0.05, green: 0.08, blue: 0.20)   // very dark navy (phrase side)
    static let chipOut = Color(red: 0.38, green: 0.52, blue: 0.70)   // light steel (output side)
    static let chipStop = Color(red: 0.60, green: 0.22, blue: 0.26)  // muted red (STOP output)
    static let glassEdge = LinearGradient(
        colors: [.white.opacity(0.65), .white.opacity(0.12)],
        startPoint: .top, endPoint: .bottom)

    /// Flowing blue satin via a mesh of blues (sheen + folds). Linear fallback < iOS 18.
    @ViewBuilder static var silkBackground: some View {
        if #available(iOS 18.0, *) {
            // 4×4 mesh: bright speculars and dark valleys alternate on the diagonal so
            // the blend reads as flowing satin folds rather than a flat gradient.
            MeshGradient(width: 4, height: 4, points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(0.33, 0), SIMD2<Float>(0.66, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.34), SIMD2<Float>(0.26, 0.30), SIMD2<Float>(0.68, 0.38), SIMD2<Float>(1, 0.31),
                SIMD2<Float>(0, 0.66), SIMD2<Float>(0.34, 0.71), SIMD2<Float>(0.73, 0.61), SIMD2<Float>(1, 0.69),
                SIMD2<Float>(0, 1), SIMD2<Float>(0.33, 1), SIMD2<Float>(0.66, 1), SIMD2<Float>(1, 1),
            ], colors: [
                silkBright, silkDeep, silkDark, silkAzure,
                silkAzure, silkHi, silkBright, silkDark,
                silkDark, silkBright, silkHi, silkDeep,
                silkDeep, silkDark, silkAzure, silkBright,
            ])
        } else {
            LinearGradient(colors: [silkDark, silkBright, silkAzure, silkDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
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
            let font: CGFloat = big ? 19 : 12
            let pairW: CGFloat = big ? 320 : 178
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

    /// Bicolor chip: phrase (dark-indigo glass) and output (steel glass) meet along a
    /// diagonal slant, wrapped in glass chrome (frosted material + lit edge + shadow).
    private func singleCell(_ item: CheatItem, fontSize: CGFloat) -> some View {
        glassChrome(
            slantBicolor(say: item.say, out: item.out, outColor: Self.chipOut,
                         fontSize: fontSize, sayFills: false)
        )
        .fixedSize()
    }

    /// A START/STOP mode as one fixed-width two-row cell sharing the glass chrome:
    /// START on top (steel output), STOP below (red output) — reads as one toggle.
    private func pairCell(_ p: ModePair, fontSize: CGFloat, width: CGFloat) -> some View {
        glassChrome(
            VStack(spacing: 1) {
                slantBicolor(say: p.start.say.uppercased(), out: p.start.out,
                             outColor: Self.chipOut, fontSize: fontSize, sayFills: true)
                slantBicolor(say: p.stop.say.uppercased(), out: p.stop.out,
                             outColor: Self.chipStop, fontSize: fontSize, sayFills: true)
            }
            .frame(width: width)
        )
    }

    /// The two-tone diagonally-split interior (no chrome). The phrase half and the
    /// output half are clipped to complementary slants and overlapped so their
    /// diagonal edges meet, forming a single slanted seam between the two colors.
    private func slantBicolor(say: String, out: String, outColor: Color,
                              fontSize: CGFloat, sayFills: Bool) -> some View {
        let slant: CGFloat = 11
        return HStack(spacing: -slant) {
            Text(say)
                .fontWeight(.semibold).foregroundStyle(Self.glassYellow)
                .font(.system(size: fontSize)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: sayFills ? .infinity : nil, alignment: .leading)
                .padding(.leading, 11).padding(.trailing, slant + 8).padding(.vertical, 4)
                .background(Self.chipSay.opacity(0.62))
                .clipShape(SlantLeft(slant: slant))
            Text(out)
                .fontWeight(.medium).foregroundStyle(.white)
                .font(.system(size: fontSize)).lineLimit(1)
                .padding(.trailing, 11).padding(.leading, slant + 8).padding(.vertical, 4)
                .background(outColor.opacity(0.66))
                .clipShape(SlantRight(slant: slant))
        }
    }

    /// Wrap any cell interior in glass: frosted material behind the translucent tints,
    /// a light-cast top sheen, a lit edge stroke, and a drop shadow to lift it off the silk.
    private func glassChrome<V: View>(_ content: V) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .top) {
                LinearGradient(colors: [.white.opacity(0.30), .clear],
                               startPoint: .top, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Self.glassEdge, lineWidth: 1))
            .shadow(color: .black.opacity(0.38), radius: 4, x: 0, y: 2)
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

/// Left side of a chip: a rectangle whose RIGHT edge slopes down-left by `slant`
/// (top-right at full width, bottom-right pulled in). Pairs with `SlantRight`.
struct SlantLeft: Shape {
    var slant: CGFloat
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Right side of a chip: a rectangle whose LEFT edge slopes the same way (top-left
/// pulled in, bottom-left at the edge). Overlapped with `SlantLeft` the seams meet.
struct SlantRight: Shape {
    var slant: CGFloat
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
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
