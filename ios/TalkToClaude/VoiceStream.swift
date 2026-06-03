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

    private let settings: AppSettings
    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    // Read from the audio thread in sendPCM; written on the main actor. The race
    // is benign — a stale reference just sends to a closing socket, which is a
    // no-op. nonisolated(unsafe) documents that we accept this.
    private nonisolated(unsafe) var liveTask: URLSessionWebSocketTask?

    init(settings: AppSettings) {
        self.settings = settings
        // Populate the cheat sheet immediately: prefer the last-cached server copy,
        // else the bundled default. It refreshes from the server when we connect.
        let cached = UserDefaults.standard.data(forKey: "cheatsheet_v5")
        let bundled = Bundle.main.url(forResource: "cheatsheet", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        if let data = cached ?? bundled,
           let groups = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            cheatGroups = groups.compactMap(CheatGroup.from(json:))
        }
    }

    func start(session: String) {
        guard task == nil else { return }
        guard let url = URL(string: "ws://\(settings.macIP):\(settings.portNumber)/stream") else {
            lastError = "Bad server URL"
            return
        }
        let t = urlSession.webSocketTask(with: url)
        task = t
        liveTask = t
        finals.removeAll()
        lastError = ""
        listening = true
        status = "Connecting…"
        t.resume()

        // First frame: the JSON config with token + target tmux session.
        let cfg: [String: Any] = ["token": settings.token, "session": session]
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

    func stop() {
        listening = false
        speaking = false
        connected = false
        status = "Stopped"
        spellMode = false
        capsMode = "none"
        liveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Fire-and-forget PCM send. Safe to call from the real-time audio thread.
    nonisolated func sendPCM(_ data: Data) {
        liveTask?.send(.data(data)) { _ in }
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
            case .failure(let error):
                Task { @MainActor in
                    self.connected = false
                    if self.listening {
                        self.status = "Disconnected — tap the mic to retry"
                        self.lastError = error.localizedDescription
                        self.listening = false
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            connected = true
            status = "Listening…"
        case "speech_start":
            speaking = true
            status = "Hearing you…"
        case "final":
            speaking = false
            status = "Listening…"
            if let line = obj["text"] as? String, !line.isEmpty {
                finals.insert(line, at: 0)
                if finals.count > 50 { finals.removeLast() }
            }
        case "error":
            lastError = (obj["error"] as? String) ?? "server error"
        case "cheatsheet":
            if let groups = obj["groups"] as? [[String: Any]] {
                cheatGroups = groups.compactMap(CheatGroup.from(json:))
                if let data = try? JSONSerialization.data(withJSONObject: groups) {
                    UserDefaults.standard.set(data, forKey: "cheatsheet_v5")
                }
            }
        case "mode":
            spellMode = (obj["spell"] as? Bool) ?? false
            capsMode = (obj["caps"] as? String) ?? "none"
        default:
            break
        }
    }
}
