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
    @State private var showSessions: Bool     // collapsible Claude-session column
    @AppStorage("transcriptHeight") private var transcriptHeight = 150.0  // resizable box
    @State private var activeDialog: MarkdownDialogKind? = nil   // open markdown-input sheet
    @AppStorage("chipLangItalian") private var italian = false   // EN/IT chip toggle
    @AppStorage("didCompleteOnboarding") private var didOnboard = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _voice = StateObject(wrappedValue: VoiceStream(settings: s))
        _claude = StateObject(wrappedValue: ClaudeClient(settings: s))
        // The sessions sidebar is an iPad-style split column. On a narrow iPhone it
        // stole ~42% of the width, forcing the un-scalable cheat-sheet chips off the
        // right edge. Default it OPEN only on iPad; the iPhone opens it via the ☰
        // toggle. Idiom (not size class, which isn't known at init) avoids a first
        // -frame flash.
        _showSessions = State(initialValue: UIDevice.current.userInterfaceIdiom == .pad)
    }

    var body: some View {
        ZStack {
            FluxBackground().ignoresSafeArea()
            GeometryReader { geo in
                let compact = hSize == .compact
                HStack(spacing: 0) {
                    // iPad (regular width): the sidebar is a permanent split column that
                    // RESERVES width. iPhone (compact): it must NOT reserve width — doing
                    // so shrank the un-scalable cheat-sheet chips until they clipped off
                    // the right edge — so on compact it's rendered as the overlay drawer
                    // below instead of inline here.
                    if showSessions && !compact {
                        sessionsSidebar
                            .frame(width: min(240, max(150, geo.size.width * 0.42)))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 0) {
                        cheatSheet
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        bottomBar()
                    }
                }
                // iPhone drawer: the sidebar floats OVER the chips (behind a tap-to-dismiss
                // scrim) so opening it never steals width from — and never clips — the
                // cheat-sheet. Selecting a session auto-closes it (see selectSession).
                if showSessions && compact {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showSessions = false }
                        }
                    HStack(spacing: 0) {
                        sessionsSidebar
                            .frame(width: min(300, geo.size.width * 0.82))
                            .transition(.move(edge: .leading))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        // Fixed dark-glass appearance regardless of the device's light/dark setting.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, claude: claude) }
        .sheet(isPresented: $showSearch) { CheatSheetView(groups: voice.cheatGroups) }
        // Markdown input sheet (numbered/bullet/quote/link/code) → composed text to Claude.
        .sheet(item: $activeDialog) { kind in
            MarkdownDialog(kind: kind) { composed in
                tapFeedback(); Task { await claude.sendPaste(composed) }
            }
        }
        // First launch: explain the free Mac companion server and how to install it.
        .fullScreenCover(isPresented: Binding(
            get: { !didOnboard },
            set: { presented in if !presented { didOnboard = true } }
        )) {
            OnboardingView { didOnboard = true }
        }
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
        // Toggling these in Settings applies to the LIVE stream immediately (no reconnect).
        .onChange(of: settings.prefixMode) { _, on in
            if voice.listening { voice.sendControl(prefixMode: on) }
        }
        .onChange(of: settings.autoSend) { _, on in
            if voice.listening { voice.sendControl(autoSend: on) }
        }
        // Pause-to-end slider applies LIVE to the running segmenter (no mic toggle needed).
        .onChange(of: settings.pauseThreshold) { _, sec in
            if voice.listening { voice.sendControl(silenceHold: sec) }
        }
        // Success haptic the moment the server is READY — the cue to start speaking, so
        // the user doesn't talk during startup and lose the first words.
        .onChange(of: voice.connected) { _, ready in
            if ready { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    // Glass-chip palette (the ffflux background lives in FluxBackground).
    // Bright near-white yellow: low saturation so it reads almost white, but still a
    // distinct warm hue vs the pure-white output side of a tag.
    static let glassYellow = Color(hue: 0.14, saturation: 0.32, brightness: 1.0)
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

    /// Deep-link into the Tailscale app so the user can switch the VPN on (iOS can't
    /// enable a VPN programmatically — only the Tailscale app can, with user consent).
    /// Falls back to the App Store if Tailscale isn't installed.
    private func openTailscale() {
        UIApplication.shared.open(URL(string: "tailscale://")!) { ok in
            if !ok, let store = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") {
                UIApplication.shared.open(store)
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
            audio.onLevel = { [weak voice] lvl in voice?.reportLevel(lvl) }
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

    /// Make `s` the dictation target + focus its tab on the Mac. If the mic is live,
    /// retarget the OPEN stream instantly (no reconnect) — the audio keeps flowing and
    /// only the injection target changes; the server resets its editable line so a
    /// half-typed line can't carry over to the new Claude.
    private func selectSession(_ s: ClaudeSession) {
        tapFeedback()
        settings.session = s.target
        Task { await claude.focusSession(s.target) }   // bring its tab to the front on the Mac
        if voice.listening { voice.sendControl(session: s.target) }
        // On iPhone the sidebar is a modal drawer — close it once a target is picked.
        if hSize == .compact { withAnimation(.easeInOut(duration: 0.2)) { showSessions = false } }
    }

    /// The session object for the current target (nil if the chosen Claude isn't in
    /// the live list — e.g. it exited). Drives the "talking to" indicator.
    private var selectedSession: ClaudeSession? {
        claude.sessions.first { $0.target == settings.session }
    }

    /// The tab name to display: the terminal tab title, falling back to the folder.
    private func tabName(_ s: ClaudeSession) -> String {
        let t = (s.title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? s.label : t
    }

    // MARK: - Cheat sheet (variable-width chips that wrap; START/STOP modes paired)

    private var cheatSheet: some View {
        GeometryReader { geo in
            // Pick sizing by HEIGHT, not width: an iPad stays tall in Split View even
            // when its pane is narrow, so we keep the natural (un-scaled) iPad font and
            // let the grid REFLOW into fewer columns / more rows. Only a genuinely short
            // iPhone screen drops to the compact font. Chips must never be scaled down.
            // Big buttons on iPad, always — keyed to the device IDIOM, not height. (Height
            // >= 900 failed on an 11" iPad in PORTRAIT, where the chip area is < 900pt, so
            // it wrongly fell back to the tiny iPhone size.)
            let tall = UIDevice.current.userInterfaceIdiom == .pad
            // Server commands + app-only markdown-dialog tags (link, big code paste).
            let all = voice.cheatGroups.flatMap { $0.items } + Self.markdownExtras
            let singles = all.filter { $0.pair == nil }
            let pairs = modePairs(from: all)
            // Group related/opposite commands (arrows, undo/redo, open/close brackets, …)
            // into vertically-stacked cells so they read as one unit; lone chips stay solo.
            let groups = chipGroups(singles)
            // iPad chips are BIG buttons — ~3× the compact iPhone font. Italian phrases run
            // longer, so the iPhone compact size shrinks a touch.
            let font: CGFloat = tall ? 25 : (italian ? 8 : 9.5)
            // EVERY tag is the SAME width — solo, grouped, and mode-pair alike — so they
            // line up as identical buttons in clean columns. iPad width is sized so 2–3
            // columns fit while still fitting the longest label ("START REPLACE MODE").
            let tagW: CGFloat = tall ? 330 : (italian ? 168 : 150)
            let tagGap: CGFloat = tall ? 8 : 3
            // Fixed columns on BOTH platforms; FlowLayout MASONRY-packs each column
            // independently (shortest-column first) so tall groups next to short singles
            // leave NO vertical holes.
            let cols = max(1, Int((geo.size.width - 20) / (tagW + tagGap)))
            VStack(spacing: 0) {
              if settings.prefixMode { prefixBanner }
              ScrollView {
                if all.isEmpty {
                    Text("Tap the mic once to load the command list.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    // On an iPad we snap chips to a column grid so rows line up vertically;
                    // the column count follows the pane width. LEFT-justified so the big
                    // buttons align in clean left-edged columns. The iPhone tight-packs
                    // (columns: 0) to fit its small screen.
                    FlowLayout(spacing: tagGap, columns: cols, rightAligned: false) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                            if g.count == 1 {
                                singleCell(g[0], fontSize: font, width: tagW)
                            } else {
                                clusterCell(g, fontSize: font, width: tagW)
                            }
                        }
                        ForEach(pairs) { pairCell($0, fontSize: font, width: tagW) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height - (settings.prefixMode ? 40 : 0), alignment: .leading)
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

    /// Which vertical cluster a standalone chip belongs to — opposites and same-function
    /// commands share a key so they render stacked as one group. Keyed on the English
    /// `say` (language-independent). nil → the chip stays solo.
    private func clusterKey(for item: CheatItem) -> String? {
        switch item.say.lowercased() {
        case "enter", "new line":                              return "return"
        case "tab", "shift tab":                               return "tab"
        case "backspace", "forward delete":                    return "erase"
        case "arrow up", "arrow down", "arrow left", "arrow right": return "arrows"
        case "home", "line end":                               return "homeend"
        case "page up", "page down":                           return "paging"
        case "undo", "redo":                                   return "history"
        case "open quotes", "close quotes":                    return "dquotes"
        case "open code block", "close code block":            return "fence"
        case "open parentheses", "close parentheses":          return "paren"
        case "open square brackets", "close square brackets":  return "square"
        case "open curly braces", "close curly braces":        return "curly"
        case "less than", "greater than":                      return "angle"
        case "heading", "heading two", "heading three":        return "headings"
        case "bold", "italic", "strikethrough":                return "emphasis"
        default:                                               return nil
        }
    }

    /// Partition chips into ordered groups: related chips (same clusterKey) collect into
    /// one multi-item group, everything else is its own singleton. First-appearance order
    /// is preserved so the layout stays stable.
    private func chipGroups(_ items: [CheatItem]) -> [[CheatItem]] {
        var order: [String] = []
        var buckets: [String: [CheatItem]] = [:]
        for (i, it) in items.enumerated() {
            let key = clusterKey(for: it) ?? "solo-\(i)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(it)
        }
        return order.map { buckets[$0]! }
    }

    /// One TAPPABLE command row: the bicolor chip in a Button that either fires a command
    /// (/command, interpreted server-side like speech) or opens a markdown-input dialog.
    /// TagButtonStyle supplies the glow + push-down; the haptic fires in rowTapped.
    private func commandRow(_ item: CheatItem, display: String, outColor: Color,
                            fontSize: CGFloat) -> some View {
        Button { rowTapped(item) } label: {
            slantBicolor(say: display, out: item.out, outColor: outColor,
                         fontSize: fontSize, sayFills: true)
        }
        .buttonStyle(TagButtonStyle())
    }

    /// Tap action: markdown tags open an input dialog; every other tag is sent to the
    /// selected Claude via /command.
    private func rowTapped(_ item: CheatItem) {
        if let kind = MarkdownDialogKind(say: item.say) {
            activeDialog = kind
            return
        }
        tapFeedback()
        Task { await claude.sendCommand(item.say) }
    }

    /// A cluster of related chips as one fixed-width cell — each member its own tappable
    /// row (open=green, close=red, else steel), sharing the glass chrome.
    private func clusterCell(_ items: [CheatItem], fontSize: CGFloat, width: CGFloat) -> some View {
        glassChrome(
            VStack(spacing: 1) {
                ForEach(items) { it in
                    commandRow(it, display: italian ? it.sayIt : it.say,
                               outColor: toneColor(for: it), fontSize: fontSize)
                }
            }
            .frame(width: width)
        )
    }

    /// A single tappable command tag.
    private func singleCell(_ item: CheatItem, fontSize: CGFloat, width: CGFloat) -> some View {
        glassChrome(
            commandRow(item, display: italian ? item.sayIt : item.say,
                       outColor: toneColor(for: item), fontSize: fontSize)
                .frame(width: width)
        )
    }

    /// A mode as one fixed-width cell: START (green), optional REPLACE-WITH (steel), STOP
    /// (red) — each a tappable row.
    private func pairCell(_ p: ModePair, fontSize: CGFloat, width: CGFloat) -> some View {
        glassChrome(
            VStack(spacing: 1) {
                commandRow(p.start, display: (italian ? p.start.sayIt : p.start.say).uppercased(),
                           outColor: Self.chipOpen, fontSize: fontSize)
                if let mid = p.middle {
                    commandRow(mid, display: (italian ? mid.sayIt : mid.say).uppercased(),
                               outColor: Self.chipOut, fontSize: fontSize)
                }
                commandRow(p.stop, display: (italian ? p.stop.sayIt : p.stop.say).uppercased(),
                           outColor: Self.chipClose, fontSize: fontSize)
            }
            .frame(width: width)
        )
    }

    /// App-only markdown-dialog tags appended to the palette (not server commands).
    static let markdownExtras: [CheatItem] = [
        CheatItem(say: "insert link", sayIt: "inserisci link", out: "[](url)", label: "link",
                  triggers: ["insert link"], pair: nil, role: nil),
        CheatItem(say: "paste code", sayIt: "incolla codice", out: "````", label: "code",
                  triggers: ["paste code"], pair: nil, role: nil),
    ]

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
                .minimumScaleFactor(0.85)   // keep sizes near-uniform; tiny safety for the longest labels
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

    private func bottomBar() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 0 — which Claude you're talking to: tab name + work dir (always
            // visible, even with the sidebar collapsed, so you know to switch if needed).
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: selectedSession != nil ? "target" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(selectedSession != nil ? Color.green : .orange)
                    .padding(.top, 1)
                if let sel = selectedSession {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(tabName(sel)).font(.subheadline.weight(.heavy))
                                .foregroundStyle(.white).lineLimit(1)
                            Text(sel.kind == "iterm" ? "iTerm" : (sel.kind == "terminal" ? "Term" : "tmux"))
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        // Work dir — full path, head-truncated so the project folder stays visible.
                        Text(sel.cwd.isEmpty ? sel.label : sel.cwd)
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.head)
                    }
                } else {
                    Text(settings.session.isEmpty
                         ? "No Claude selected — tap one in the list"
                         : "Selected Claude isn’t running — pick another")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // Row 1 — big status labels + (bold red) errors, full width so they never wrap.
            HStack(spacing: 9) {
                statusLabel(voice.connected ? "CONNECTED" : "OFFLINE",
                            color: voice.connected ? .green : .gray)
                phaseChip()
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
            // Live mic level — instant visual feedback that audio is being captured,
            // even before any text is decoded.
            if voice.listening || voice.transcribing {
                levelMeter
            }
            // Tailscale call-to-action — shown when the server IP is a Tailscale address
            // we can't reach: invite the user to open Tailscale and switch the VPN on.
            if voice.tailscaleOffLikely {
                Button { tapFeedback(); openTailscale() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 15, weight: .bold))
                        Text("Tailscale looks OFF — tap to open it and turn the VPN on")
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            // Row 2 — the session transcript: a resizable, scrollable terminal-style box.
            TranscriptView(lines: voice.finals, height: $transcriptHeight,
                           onClear: { voice.clearTranscript() })
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

    /// The mic lifecycle, derived from VoiceStream's flags — a single source of truth so
    /// the label can't disagree with the button.
    private enum MicPhase { case idle, starting, ready, hearing, transcribing }
    private var micPhase: MicPhase {
        if voice.transcribing { return .transcribing }   // also covers the flush "Finishing…"
        if voice.speaking { return .hearing }
        if voice.listening { return voice.connected ? .ready : .starting }
        return .idle
    }

    /// Phase chip — replaces the old REC/LISTENING/IDLE label with an explicit lifecycle
    /// so the user knows when the system is still warming up vs ready to speak.
    private func phaseChip() -> some View {
        let (text, color): (String, Color) = {
            switch micPhase {
            case .idle:         return ("IDLE", .gray)
            case .starting:     return ("STARTING…", .yellow)
            case .ready:        return ("READY — SPEAK", .green)
            case .hearing:      return ("REC", .red)
            case .transcribing: return ("TRANSCRIBING…", .teal)
            }
        }()
        return statusLabel(text, color: color)
    }

    /// Slim live input-level meter (green→orange fill), driven by VoiceStream.level. Gives
    /// instant "I hear you" feedback before any text is decoded.
    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, voice.level)))))
                    .animation(.linear(duration: 0.08), value: voice.level)
            }
        }
        .frame(height: 6)
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

/// Terminal-style session transcript: a resizable, drag-scrollable box (native iOS
/// elastic bounce) showing every utterance of the session in monospaced text — oldest at
/// the top, newest at the bottom and brightest, older lines fading. Auto-scrolls to the
/// newest line as it arrives; drag the handle at the bottom to resize.
struct TranscriptView: View {
    let lines: [String]              // newest-first, as VoiceStream stores them
    @Binding var height: Double
    var onClear: () -> Void

    private let minHeight: Double = 90
    private let maxHeight: Double = 460
    private let bottomID = "transcript-bottom"
    @State private var dragStart: Double? = nil
    @State private var confirmClear = false

    var body: some View {
        let ordered = Array(lines.reversed())   // chronological: oldest → newest
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("TRANSCRIPT").font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear transcript log", systemImage: "trash")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(lines.isEmpty ? 0.3 : 0.75))
                .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
            .confirmationDialog("Clear the entire transcript log?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear transcript log", role: .destructive) { onClear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the whole session transcript. It can't be undone.")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if ordered.isEmpty {
                            Text("— your transcript will appear here —")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(ordered.enumerated()), id: \.offset) { idx, line in
                            let ageFromNewest = ordered.count - 1 - idx    // 0 = newest
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.white.opacity(
                                    ageFromNewest == 0 ? 1.0 : max(0.32, 1.0 - Double(ageFromNewest) * 0.12)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .frame(height: height)
            .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))

            // Drag handle to resize the box (clamped). Persists via the bound @AppStorage.
            Capsule().fill(.white.opacity(0.35)).frame(width: 42, height: 5)
                .padding(.vertical, 6).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let base = dragStart ?? height
                            if dragStart == nil { dragStart = height }
                            height = min(maxHeight, max(minHeight, base + Double(v.translation.height)))
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
    }
}

/// Button feedback for a command tag: pressing pushes down (scale), brightens, and casts
/// an inner white glow — like a lit key lighting up. Haptic is fired by the tap handler.
struct TagButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.22 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.28 : 0))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .shadow(color: .white.opacity(configuration.isPressed ? 0.7 : 0),
                    radius: configuration.isPressed ? 12 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The markdown-input tags that open a compose/paste dialog. `init?(say:)` maps a tag's
/// English phrase to its kind (nil for ordinary tags).
enum MarkdownDialogKind: String, Identifiable {
    case numbered, bullet, quote, link, code
    var id: String { rawValue }

    init?(say: String) {
        switch say.lowercased() {
        case "numbered item": self = .numbered
        case "bullet":        self = .bullet
        case "quote block":   self = .quote
        case "insert link":   self = .link
        case "paste code":    self = .code
        default:              return nil
        }
    }

    var title: String {
        switch self {
        case .numbered: return "Numbered list"
        case .bullet:   return "Bulleted list"
        case .quote:    return "Quote block"
        case .link:     return "Insert link"
        case .code:     return "Paste code block"
        }
    }
    var prompt: String {
        switch self {
        case .numbered, .bullet: return "One item per line — paste or type your list."
        case .quote:             return "Paste or type the text to quote."
        case .link:              return "Link text and URL."
        case .code:              return "Paste your code — it's wrapped in 4 backticks."
        }
    }
}

/// A sheet that composes a markdown block from pasted/typed input, then sends it to Claude
/// as one multi-line prompt. Works on iPhone and iPad (standard Form/sheet).
struct MarkdownDialog: View {
    let kind: MarkdownDialogKind
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var linkText = ""
    @State private var linkURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(kind.prompt).font(.footnote).foregroundStyle(.secondary) }
                if kind == .link {
                    Section("Text") { TextField("link text", text: $linkText) }
                    Section("URL") {
                        TextField("https://…", text: $linkURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                } else {
                    Section {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSubmit(compose()); dismiss() }.disabled(isEmpty)
                }
            }
        }
    }

    private var isEmpty: Bool {
        kind == .link ? linkURL.trimmingCharacters(in: .whitespaces).isEmpty
                      : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Turn the raw input into markdown per kind.
    private func compose() -> String {
        switch kind {
        case .numbered:
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .bullet:
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            return lines.map { "- \($0)" }.joined(separator: "\n")
        case .quote:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.map { "> \($0)" }.joined(separator: "\n")
        case .code:
            return "````\n\(text)\n````"
        case .link:
            let t = linkText.trimmingCharacters(in: .whitespaces)
            let u = linkURL.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? u : "[\(t)](\(u))"
        }
    }
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
            // MASONRY: every chip is one slot wide; place each in the SHORTEST column so
            // tall groups and short singles interleave with NO vertical holes. Left-packed.
            let slotW = (maxWidth + spacing) / CGFloat(columns)
            var colY = Array(repeating: CGFloat(0), count: columns)
            for (i, sv) in subviews.enumerated() {
                let s = sv.sizeThatFits(.unspecified)
                var col = 0
                for c in 1..<columns where colY[c] < colY[col] - 0.5 { col = c }
                spots.append((i, CGFloat(col) * slotW, colY[col], s))
                colY[col] += s.height + spacing
            }
            let maxH = colY.max() ?? 0
            return (maxWidth, max(0, maxH - spacing), spots)
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
