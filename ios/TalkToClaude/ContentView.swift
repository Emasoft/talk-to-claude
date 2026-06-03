import SwiftUI
import AVFoundation
import AudioToolbox

struct ContentView: View {
    @StateObject private var settings: AppSettings
    @StateObject private var voice: VoiceStream
    @StateObject private var claude: ClaudeClient
    @State private var audio = AudioStreamer()
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showSessions = true   // collapsible Claude-session column
    @AppStorage("chipLangItalian") private var italian = false   // EN/IT chip toggle
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
            FluxBackground().ignoresSafeArea()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if showSessions {
                        sessionsSidebar
                            .frame(width: min(240, max(150, geo.size.width * 0.42)))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 0) {
                        cheatSheet
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Transcript line count scales with screen height (min 3).
                        bottomBar(transcriptLines: max(3, min(8, Int(geo.size.height / 200))))
                    }
                }
            }
        }
        // Fixed dark-glass appearance regardless of the device's light/dark setting.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, claude: claude) }
        .sheet(isPresented: $showSearch) { CheatSheetView(groups: voice.cheatGroups) }
        .onAppear { AVAudioApplication.requestRecordPermission { _ in } }
        .task {
            // Keep the Claude-session sidebar fresh while the app is foreground.
            while !Task.isCancelled {
                await claude.loadSessions()
                // Auto-pick the first Claude ONLY when nothing has ever been chosen
                // (empty, or the legacy "default" placeholder). A real selection is
                // never overridden — so the Claude you pick is remembered across
                // launches even if it briefly drops off the list.
                if settings.session.isEmpty || settings.session == "default",
                   let first = claude.sessions.first {
                    settings.session = first.target
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && voice.listening {
                audio.stop()
                voice.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // Glass-chip palette (the ffflux background lives in FluxBackground).
    static let glassYellow = Color(hue: 0.13, saturation: 0.55, brightness: 1.0)
    static let chipSay = Color(red: 0.05, green: 0.08, blue: 0.20)   // very dark navy (phrase side)
    static let chipOut = Color(red: 0.38, green: 0.52, blue: 0.70)   // neutral steel (output side)
    static let chipOpen = Color(red: 0.18, green: 0.55, blue: 0.36)  // green tone: open / start
    static let chipClose = Color(red: 0.70, green: 0.22, blue: 0.30) // red tone: close / stop
    static let glassEdge = LinearGradient(
        colors: [.white.opacity(0.65), .white.opacity(0.12)],
        startPoint: .top, endPoint: .bottom)

    /// Output-side tint by role: green for OPEN, red for CLOSE, steel for everything
    /// else. (Keyed on the English `say` so it's language-independent.)
    private func toneColor(for item: CheatItem) -> Color {
        if item.say.hasPrefix("open ") { return Self.chipOpen }
        if item.say.hasPrefix("close ") { return Self.chipClose }
        return Self.chipOut
    }

    /// Click sound + light haptic for every on-screen button.
    private func tapFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioServicesPlaySystemSound(1104)   // soft keyboard-tap click
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

    // MARK: - Claude-session sidebar (collapsible column of running claude instances)

    /// The collapsible left column listing every running Claude Code instance the
    /// Mac discovered (tmux, excluding ai-maestro). Tap one to make it the dictation
    /// target; the ☰ button in the bottom bar (or the chevron here) hides the column.
    private var sessionsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("CLAUDES").font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Button { tapFeedback(); Task { await claude.loadSessions() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption.weight(.bold))
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                Button {
                    tapFeedback()
                    withAnimation(.easeInOut(duration: 0.2)) { showSessions = false }
                } label: {
                    Image(systemName: "sidebar.leading").font(.caption.weight(.bold))
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            if claude.sessions.isEmpty {
                Text("No Claude sessions found.\nStart `claude` in a tmux window, then tap ⟳.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(claude.sessions) { sessionRow($0) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.12)).frame(width: 1) }
    }

    private func sessionRow(_ s: ClaudeSession) -> some View {
        let selected = settings.session == s.target
        let title = (s.title ?? "").trimmingCharacters(in: .whitespaces)
        let subtitle = title.isEmpty ? folderName(s.cwd) : title
        return Button { selectSession(s) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.green : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(s.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(s.kind == "iterm" ? "iTerm" : (s.kind == "terminal" ? "Term" : "tmux"))
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    Text(subtitle).font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.green.opacity(0.18) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.green.opacity(0.55) : .white.opacity(0.12), lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Last path component of a working directory (for the dimmed second line).
    private func folderName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let leaf = (trimmed as NSString).lastPathComponent
        return leaf.isEmpty ? trimmed : leaf
    }

    /// Make `s` the dictation target. If we're already streaming, reconnect so the
    /// new target takes effect immediately (the target is sent only at connect time).
    private func selectSession(_ s: ClaudeSession) {
        tapFeedback()
        settings.session = s.target
        Task { await claude.focusSession(s.target) }   // bring its tab to the front on the Mac
        guard voice.listening else { return }
        voice.stop()
        audio.stop()
        audio.onPCM = { [weak voice] data in voice?.sendPCM(data) }
        do {
            try audio.start()
            voice.start(session: settings.session)
        } catch {
            voice.lastError = "Mic restart failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Cheat sheet (variable-width chips that wrap; START/STOP modes paired)

    private var cheatSheet: some View {
        GeometryReader { geo in
            // Pick sizing by HEIGHT, not width: an iPad stays tall in Split View even
            // when its pane is narrow, so we keep the natural (un-scaled) iPad font and
            // let the grid REFLOW into fewer columns / more rows. Only a genuinely short
            // iPhone screen drops to the compact font. Chips must never be scaled down.
            let tall = geo.size.height >= 900        // iPad-class pane (full OR Split View)
            let big = geo.size.width >= 980          // room for the full 6-column grid
            let all = voice.cheatGroups.flatMap { $0.items }
            let singles = all.filter { $0.pair == nil }
            let pairs = modePairs(from: all)
            // Italian phrases run longer, so the compact iPhone font shrinks a touch.
            let font: CGFloat = tall ? 18 : (italian ? 8 : 9.5)
            let pairW: CGFloat = tall ? 300 : (italian ? 168 : 150)
            // Column count tracks the available WIDTH so a narrow Split-View pane reflows
            // to fewer (but full-size) columns instead of squeezing all six in. The full
            // iPad keeps its 6-column grid; the iPhone tight-wraps (columns: 0).
            let cols = tall ? (big ? 6 : max(2, min(5, Int(geo.size.width / 200)))) : 0
            VStack(spacing: 0) {
              if settings.prefixMode { prefixBanner }
              ScrollView {
                if all.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    // On an iPad we snap chips to a column grid so rows line up
                    // vertically; the column count follows the pane width, so a narrow
                    // Split-View pane reflows to fewer full-size columns (chips are never
                    // scaled). The iPhone tight-packs (columns: 0) to fit its small screen.
                    // Right-aligned: the output symbols line up near the right edge so
                    // you can scan a column of symbols, then read the phrase to its left.
                    FlowLayout(spacing: tall ? 6 : 3, columns: cols, rightAligned: true) {
                        ForEach(singles) { singleCell($0, fontSize: font) }
                        ForEach(pairs) { pairCell($0, fontSize: font, width: pairW) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height - (settings.prefixMode ? 40 : 0), alignment: .trailing)
                }
              }
            }
        }
    }

    /// Slim reminder shown above the chips while prefix mode is on. The prefix word is
    /// constant for every chip, so it lives here once instead of bloating all ~70 chips
    /// (which would re-widen them and undo the Split-View reflow). Also surfaces the
    /// active "command symbols" burst.
    private var prefixBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "command").font(.caption2.weight(.bold))
            Text(italian ? "Di’ “comando” prima di un comando" : "Say “command” before a command")
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            if voice.symbolsMode {
                Text(italian ? "· SIMBOLI" : "· SYMBOLS")
                    .font(.caption2.weight(.heavy)).foregroundStyle(Self.glassYellow)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    /// Collapse the START/STOP (and optional WITH) rules sharing a `pair` into ordered
    /// groups. REPLACE has a middle "replace with" row; the others are just start/stop.
    private func modePairs(from items: [CheatItem]) -> [ModePair] {
        var byName: [String: (start: CheatItem?, middle: CheatItem?, stop: CheatItem?)] = [:]
        var order: [String] = []
        for it in items {
            guard let p = it.pair else { continue }
            if byName[p] == nil { byName[p] = (nil, nil, nil); order.append(p) }
            switch it.role {
            case "stop": byName[p]?.stop = it
            case "with": byName[p]?.middle = it
            default: byName[p]?.start = it
            }
        }
        return order.compactMap { name in
            guard let e = byName[name], let s = e.start, let t = e.stop else { return nil }
            return ModePair(id: name, start: s, middle: e.middle, stop: t)
        }
    }

    /// Bicolor chip: phrase (dark-indigo glass) and output (steel glass) meet along a
    /// diagonal slant, wrapped in glass chrome (frosted material + lit edge + shadow).
    private func singleCell(_ item: CheatItem, fontSize: CGFloat) -> some View {
        glassChrome(
            slantBicolor(say: italian ? item.sayIt : item.say, out: item.out, outColor: toneColor(for: item),
                         fontSize: fontSize, sayFills: false)
        )
        .fixedSize()
    }

    /// A mode rendered as one fixed-width cell sharing the glass chrome: START on top
    /// (green), STOP at the bottom (red), and — for REPLACE — a middle "REPLACE WITH"
    /// row (steel). So delete is 2 rows; replace is 3.
    private func pairCell(_ p: ModePair, fontSize: CGFloat, width: CGFloat) -> some View {
        glassChrome(
            VStack(spacing: 1) {
                slantBicolor(say: (italian ? p.start.sayIt : p.start.say).uppercased(), out: p.start.out,
                             outColor: Self.chipOpen, fontSize: fontSize, sayFills: true)
                if let mid = p.middle {
                    slantBicolor(say: (italian ? mid.sayIt : mid.say).uppercased(), out: mid.out,
                                 outColor: Self.chipOut, fontSize: fontSize, sayFills: true)
                }
                slantBicolor(say: (italian ? p.stop.sayIt : p.stop.say).uppercased(), out: p.stop.out,
                             outColor: Self.chipClose, fontSize: fontSize, sayFills: true)
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
                .font(.system(size: fontSize)).lineLimit(1)
                .minimumScaleFactor(sayFills ? 0.6 : 1)   // singles never scale; only fixed-width pairs may
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

    private func bottomBar(transcriptLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1 — big status labels + (bold red) errors, full width so they never wrap.
            HStack(spacing: 9) {
                statusLabel(voice.connected ? "CONNECTED" : "OFFLINE",
                            color: voice.connected ? .green : .gray)
                statusLabel(voice.speaking ? "REC" : (voice.listening ? "LISTENING" : "IDLE"),
                            color: voice.speaking ? .red : (voice.listening ? .orange : .gray))
                if voice.capsMode == "upper" { modeBadge("CAPS", .orange) }
                if voice.capsMode == "lower" { modeBadge("abc", .blue) }
                if voice.spellMode { modeBadge("SPELL", .purple) }
                if !voice.editMode.isEmpty {
                    modeBadge(voice.editMode == "delete" ? "DELETE" : "REPLACE", .red)
                }
                if voice.symbolsMode { modeBadge("SYMBOLS", .teal) }
                Spacer(minLength: 6)
                if !voice.lastError.isEmpty {
                    Text(voice.lastError)
                        .font(.subheadline.weight(.bold)).foregroundStyle(.red)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            // Row 2 — transcript, full width.
            transcriptView(lines: transcriptLines)
            // Row 3 — finger-sized controls.
            HStack(spacing: 12) {
                Button { tapFeedback(); toggleMic() } label: {
                    ZStack {
                        Circle()
                            .fill(voice.listening ? (voice.speaking ? Color.red : Color.orange) : Color.accentColor)
                            .frame(width: 58, height: 58)
                        Image(systemName: voice.listening ? "waveform" : "mic.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .symbolEffect(.variableColor, isActive: voice.speaking)
                iconButton("sidebar.leading") {
                    withAnimation(.easeInOut(duration: 0.2)) { showSessions.toggle() }
                }
                Spacer(minLength: 6)
                pillButton(italian ? "IT" : "EN") { italian.toggle() }
                iconButton("magnifyingglass") { showSearch = true }
                iconButton("gearshape") { showSettings = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Bold status pill with a coloured dot (CONNECTED / OFFLINE, REC / LISTENING / IDLE).
    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
    }

    /// Finger-sized glass icon button with click + haptic feedback.
    private func iconButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button { tapFeedback(); action() } label: {
            Image(systemName: system)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Finger-sized glass text button (the EN/IT toggle).
    private func pillButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button { tapFeedback(); action() } label: {
            Text(text)
                .font(.title3.weight(.heavy)).foregroundStyle(.white)
                .frame(width: 66, height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.9))
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The last `lines` transcribed utterances — oldest at top, newest (bright) at the
    /// bottom — padded with blanks so the row keeps a stable minimum height.
    private func transcriptView(lines: Int) -> some View {
        let recent = Array(voice.finals.prefix(lines))   // newest-first
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<lines, id: \.self) { r in
                let ageFromNewest = (lines - 1) - r       // bottom row → 0 (newest)
                let text = ageFromNewest < recent.count
                    ? recent[ageFromNewest]
                    : (ageFromNewest == 0 ? "—" : " ")
                Text(text.isEmpty ? " " : text)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(ageFromNewest == 0 ? .primary : .secondary)
                    .opacity(ageFromNewest == 0 ? 1.0 : max(0.4, 1.0 - Double(ageFromNewest) * 0.14))
            }
        }
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

/// A mode toggle assembled from `pair`-tagged cheat items: start + stop, plus an
/// optional middle row (REPLACE's "replace with").
struct ModePair: Identifiable {
    let id: String
    let start: CheatItem
    let middle: CheatItem?
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

/// Procedural ffflux background (no bitmap): a Metal fragment shader computes a
/// vertical purple gradient whose luminance is replaced by fractal noise and whose
/// saturation is tripled — the SVG's feTurbulence + feBlend(color) + saturate chain.
struct FluxBackground: View {
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(ShaderLibrary.ffflux(.float2(geo.size.width, geo.size.height)))
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
    var rightAligned: Bool = false

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
            // Right-aligned, each chip sits at the RIGHT of its span so the output
            // symbols line up down each column.
            let slotW = (maxWidth + spacing) / CGFloat(columns)
            var col = 0
            for (i, sv) in subviews.enumerated() {
                let s = sv.sizeThatFits(.unspecified)
                let span = min(columns, max(1, Int(ceil((s.width + spacing) / slotW))))
                if col + span > columns { col = 0; y += rowH + spacing; rowH = 0 }
                let x = rightAligned
                    ? CGFloat(col + span) * slotW - spacing - s.width
                    : CGFloat(col) * slotW
                spots.append((i, x, y, s))
                col += span
                rowH = max(rowH, s.height)
            }
            return (maxWidth, y + rowH, spots)
        }

        // Tight wrap: pack chips left-to-right, wrapping when out of room.
        var x: CGFloat = 0
        var rowStart = 0
        func alignRow(_ end: Int) {
            guard rightAligned, maxWidth.isFinite, end > rowStart else { return }
            let last = spots[end - 1]
            let dx = maxWidth - (last.x + last.size.width)
            if dx > 0 { for k in rowStart..<end { spots[k].x += dx } }
        }
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                alignRow(spots.count)
                x = 0; y += rowH + spacing; rowH = 0
                rowStart = spots.count
            }
            spots.append((i, x, y, s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        alignRow(spots.count)
        return (widest, y + rowH, spots)
    }
}
