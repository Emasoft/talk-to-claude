import Foundation
import Combine

/// Settings-only HTTP client for the Mac receiver (`server/voice_server.py`):
/// the "Test connection" probe and the tmux-session list. The voice path itself
/// is the WebSocket in `VoiceStream`. Plain HTTP — Tailscale (WireGuard) encrypts
/// every packet, and the bearer token authorizes the call.
/// One discovered Claude Code instance from the Mac (`GET /sessions`). `target` is
/// what the server injects into (a tmux pane address); `label`/`cwd` are for display.
struct ClaudeSession: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let kind: String      // "tmux" | "iterm" | "terminal"
    let label: String     // folder leaf (project)
    let cwd: String
    let target: String
    let title: String?    // tab/session title (e.g. the Claude task) — best recognizer
}

@MainActor
final class ClaudeClient: ObservableObject {
    @Published var connected: Bool = false
    @Published var lastError: String = ""
    @Published var sessions: [ClaudeSession] = []

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    private func makeRequest(path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: "http://\(settings.macIP):\(settings.portNumber)\(path)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Unauthenticated reachability probe used by the "Test connection" button.
    func checkHealth() async {
        guard let req = makeRequest(path: "/health") else { return }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            connected = ok
            lastError = ok ? "" : "Server reachable but returned an error"
        } catch {
            connected = false
            lastError = "Can't reach \(settings.macIP):\(settings.portNumber) — \(error.localizedDescription)"
        }
    }

    /// Refresh the running-Claude list. Only republishes values that ACTUALLY changed —
    /// otherwise every 4-second poll would fire @Published and force a full re-render of
    /// the shader background + glass chips, which bogs the device down even while idle.
    func loadSessions() async {
        guard let req = makeRequest(path: "/sessions") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if lastError.isEmpty { lastError = "Couldn't list sessions" }
                return
            }
            let decoded = try JSONDecoder().decode(SessionsResponse.self, from: data)
            if decoded.sessions != sessions { sessions = decoded.sessions }
            if !connected { connected = true }
            if !lastError.isEmpty { lastError = "" }
        } catch {
            let msg = "Couldn't list sessions — \(error.localizedDescription)"
            if lastError != msg { lastError = msg }
        }
    }

    /// Ask the Mac to bring the selected session's tab to the front (so the monitor
    /// shows the Claude you're talking to). Fire-and-forget — a failure is non-fatal.
    func focusSession(_ target: String) async {
        guard let url = URL(string: "http://\(settings.macIP):\(settings.portNumber)/focus") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": target])
        _ = try? await URLSession.shared.data(for: req)
    }

}

private struct SessionsResponse: Decodable {
    let sessions: [ClaudeSession]
}
