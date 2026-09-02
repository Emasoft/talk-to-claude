import Foundation
import Combine

/// WebSocket client for the v2 `/stream` endpoint: streams PCM16 audio up to the
/// Mac and receives transcription events back. The Mac does VAD + Whisper, so
/// this client is "dumb" — it just pumps audio and displays what comes back.
@MainActor
final class VoiceStream: ObservableObject {
    @Published var connected = false
    @Published var listening = false
    @Published var speaking = false
    @Published var status = "Tap the mic to start"
    @Published var finals: [String] = []
    @Published var lastError = ""
    @Published var cheatGroups: [CheatGroup] = []
    @Published var spellMode = false
    @Published var capsMode = "none"  // "none" | "upper" | "lower"
    @Published var editMode = ""      // "" | "delete" | "replace_find" | "replace_with"
    @Published var symbolsMode = false // prefix-mode "command symbols" burst is active
    // Set when we can't reach a Tailscale server IP and never connected this session —
    // drives the app's "Open Tailscale" call-to-action so the user can switch the VPN on.
    @Published var tailscaleOffLikely = false
    // Live mic input level 0…1 (from AudioStreamer, on the audio thread) for the meter.
    @Published var level: Float = 0
    // The utterance ended and the server is decoding it — shows "Transcribing…" between
    // the pause and the decoded text so the ~1–2s ASR latency doesn't feel dead.
    @Published var transcribing = false
    // True while a user-initiated stop is flushing the in-flight utterance: we keep the
    // socket open just long enough to receive that last final, then close.
    private var flushClosePending = false

    private let settings: AppSettings
    // A long-lived WebSocket: the server only sends data back WHEN you speak, so a long
    // thinking-pause means no downstream bytes. The default 60s request timeout would drop
    // the socket on such an idle gap ("the operation couldn't be completed"). Raise it so
    // idle pauses don't kill the connection; auto-reconnect handles genuine drops.
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 86_400   // ~1 day — effectively no idle timeout
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
    private var task: URLSessionWebSocketTask?
    // Read from the audio thread in sendPCM; written on the main actor. The race
    // is benign — a stale reference just sends to a closing socket, which is a
    // no-op. nonisolated(unsafe) documents that we accept this.
    private nonisolated(unsafe) var liveTask: URLSessionWebSocketTask?
    private var wantListening = false   // user intent — drives auto-reconnect on a drop
    private var reconnectAttempts = 0
    // Whether the socket reached "ready" at least once THIS session. Distinguishes
    // "never reached the server" (usually Tailscale/VPN off) from a mid-session drop.
    private var everConnected = false

    init(settings: AppSettings) {
        self.settings = settings
        // Populate the cheat sheet immediately: prefer the last-cached server copy,
        // else the bundled default. It refreshes from the server when we connect.
        let cached = UserDefaults.standard.data(forKey: "cheatsheet_v6")
        let bundled = Bundle.main.url(forResource: "cheatsheet", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        if let data = cached ?? bundled,
           let groups = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            cheatGroups = groups.compactMap(CheatGroup.from(json:))
        }
    }

    func start(session: String) {
        wantListening = true
        reconnectAttempts = 0
        everConnected = false
        tailscaleOffLikely = false
        transcribing = false
        flushClosePending = false
        level = 0
        finals.removeAll()
        connect(session: session)
    }

    /// Open the socket and send the config. Reused by start() and by auto-reconnect.
    private func connect(session: String) {
        guard task == nil else { return }
        guard let url = URL(string: "ws://\(settings.macIP):\(settings.portNumber)/stream") else {
            lastError = "Bad server URL"
            return
        }
        let t = urlSession.webSocketTask(with: url)
        task = t
        liveTask = t
        if reconnectAttempts == 0 { lastError = "" }   // keep a reconnect hint visible across retries
        listening = true
        status = reconnectAttempts == 0 ? "Connecting…" : "Reconnecting…"
        t.resume()

        // First frame: the JSON config — token + target session + voice tunables.
        let cfg: [String: Any] = [
            "token": settings.token,
            "session": session,
            "silence_hold": settings.pauseThreshold,  // pause (s) that ends a sentence
            "auto_send": settings.autoSend,            // submit each sentence automatically
            "prefix_mode": settings.prefixMode,        // literal-by-default; commands need "command"
            // NB: no "correct" key — transcription cleanup is always-on server-side.
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cfg),
           let json = String(data: data, encoding: .utf8) {
            t.send(.string(json)) { [weak self] error in
                if let error {
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
            }
        }
        receiveLoop()
    }

    /// User tapped stop. FLUSH the in-flight utterance first: ask the server to
    /// transcribe whatever it captured before the pause (so a half-spoken sentence isn't
    /// lost), keep the socket open just long enough to receive that last final, then
    /// close. Falls back to an immediate close if we weren't connected.
    func stop() {
        wantListening = false       // user-initiated — do NOT auto-reconnect
        level = 0
        speaking = false
        guard connected, let t = task else { finishStop(); return }
        flushClosePending = true
        transcribing = true         // decoding the flushed utterance
        listening = false
        status = "Finishing…"
        t.send(.string("{\"type\":\"flush\"}")) { _ in }
        // Safety net: if no final/flushed arrives (e.g. nothing was buffered), close anyway.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.flushClosePending { self.finishStop() }
        }
    }

    /// Tear the socket down and reset all live state. The terminal step of stop().
    private func finishStop() {
        flushClosePending = false
        reconnectAttempts = 0
        listening = false
        speaking = false
        transcribing = false
        connected = false
        level = 0
        status = "Stopped"
        spellMode = false
        capsMode = "none"
        editMode = ""
        symbolsMode = false
        tailscaleOffLikely = false
        liveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Report the live mic level (called on the audio thread) → publish on the main actor.
    nonisolated func reportLevel(_ v: Float) {
        Task { @MainActor in self.level = v }
    }

    /// Fire-and-forget PCM send. Safe to call from the real-time audio thread.
    nonisolated func sendPCM(_ data: Data) {
        liveTask?.send(.data(data)) { _ in }
    }

    /// Live reconfiguration over the OPEN socket — switch the target Claude or toggle
    /// prefix mode with no reconnect (instant). No-op when not connected.
    func sendControl(session: String? = nil, prefixMode: Bool? = nil, autoSend: Bool? = nil) {
        guard let t = task else { return }
        var obj: [String: Any] = ["type": "config"]
        if let session { obj["session"] = session }
        if let prefixMode { obj["prefix_mode"] = prefixMode }
        if let autoSend { obj["auto_send"] = autoSend }
        guard obj.count > 1,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        t.send(.string(json)) { _ in }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    Task { @MainActor in self.handle(text) }
                }
                Task { @MainActor in self.receiveLoop() }  // re-arm on the main actor
            case .failure:
                Task { @MainActor in
                    self.connected = false
                    self.task = nil
                    self.liveTask = nil
                    if self.wantListening {
                        self.scheduleReconnect()   // a drop (server restart / blip) — auto-retry
                    } else {
                        self.listening = false     // user already stopped — stay down
                    }
                }
            }
        }
    }

    /// A dropped socket (server restart, network blip, idle close) auto-reconnects with
    /// backoff while the user still wants to listen — so transient drops are an invisible
    /// "Reconnecting…" instead of a dead-end red error. Gives up after a handful of tries.
    private func scheduleReconnect() {
        guard wantListening else { return }
        reconnectAttempts += 1
        // Never reached the server AND the target is a Tailscale VPN address → the usual
        // cause is Tailscale being OFF on this device. Say so on the FIRST failure rather
        // than after 8 silent retries. A mid-session drop (everConnected == true) keeps
        // the quiet "Reconnecting…" so a brief server restart doesn't cry "VPN off".
        let tailscaleHint = !everConnected && looksLikeTailscale(settings.macIP)
        tailscaleOffLikely = tailscaleHint
        if tailscaleHint {
            lastError = "Can’t reach \(settings.macIP) — that’s a Tailscale address. Is Tailscale (VPN) ON on this device? (And is the server running on the Mac?)"
        }
        if reconnectAttempts > 8 {
            listening = false
            wantListening = false
            status = "Disconnected — tap the mic to retry"
            lastError = tailscaleHint
                ? "Couldn’t reach \(settings.macIP) (a Tailscale IP). Turn Tailscale ON on this device and the Mac, then tap the mic."
                : "Lost the connection to the Mac and couldn't reconnect — is the server running?"
            return
        }
        status = "Reconnecting…"
        let delay = min(0.4 * Double(reconnectAttempts), 3.0)   // 0.4s → 3s backoff
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.wantListening, self.task == nil else { return }
            self.connect(session: self.settings.session)
        }
    }

    /// True if `host` is a Tailscale VPN address — IPv4 CGNAT 100.64.0.0/10 (the range
    /// Tailscale hands out; NOT every 100.x) or the Tailscale IPv6 ULA prefix
    /// fd7a:115c:a1e0::/48. Only used to phrase the "can't connect" hint — it never
    /// blocks or alters a connection attempt.
    private func looksLikeTailscale(_ host: String) -> Bool {
        if host.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }   // Tailscale IPv6 ULA
        let p = host.split(separator: ".")
        if p.count == 4, let a = Int(p[0]), let b = Int(p[1]),
           a == 100, (64...127).contains(b) { return true }               // 100.64.0.0/10
        return false
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            connected = true
            everConnected = true
            tailscaleOffLikely = false
            reconnectAttempts = 0   // a successful (re)connect clears the backoff + any error
            lastError = ""
            status = "Listening…"
        case "speech_start":
            speaking = true
            transcribing = false
            status = "Hearing you…"
        case "transcribing":
            // Utterance ended; the server is decoding it. Drop the REC indicator and show
            // progress so the ASR latency doesn't feel like a dead app.
            speaking = false
            transcribing = true
            status = "Transcribing…"
        case "final":
            speaking = false
            transcribing = false
            status = flushClosePending ? "Stopped" : "Listening…"
            if let line = obj["text"] as? String, !line.isEmpty {
                finals.insert(line, at: 0)
                if finals.count > 500 { finals.removeLast() }   // whole-session scrollback
            }
            // Surface tmux-injection failures: the words were heard but never
            // reached Claude (e.g. the target session was killed).
            if let injected = obj["injected"] as? Bool {
                lastError = injected ? ""
                    : "Not delivered: \((obj["error"] as? String) ?? "tmux session unreachable")"
            }
        case "flushed":
            // Server finished the flush requested by stop() — the last final (if any) has
            // already been delivered above, so it's safe to tear the socket down now.
            if flushClosePending { finishStop() }
        case "error":
            lastError = (obj["error"] as? String) ?? "server error"
        case "cheatsheet":
            if let groups = obj["groups"] as? [[String: Any]] {
                cheatGroups = groups.compactMap(CheatGroup.from(json:))
                if let data = try? JSONSerialization.data(withJSONObject: groups) {
                    UserDefaults.standard.set(data, forKey: "cheatsheet_v6")
                }
            }
        case "mode":
            spellMode = (obj["spell"] as? Bool) ?? false
            capsMode = (obj["caps"] as? String) ?? "none"
            editMode = (obj["edit"] as? String) ?? ""
            symbolsMode = (obj["symbols"] as? Bool) ?? false
        default:
            break
        }
    }
}
