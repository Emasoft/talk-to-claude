import Foundation
import Combine

/// Talks to the Mac-side receiver (`server/claude_voice_server.py`) over the
/// Tailscale network. The wire is plain HTTP — Tailscale (WireGuard) already
/// encrypts every packet end-to-end, and the bearer token authorizes the call.
@MainActor
final class ClaudeClient: ObservableObject {
    @Published var connected: Bool = false
    @Published var lastError: String = ""
    @Published var sessions: [String] = []
    @Published var pane: String = ""

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

    /// Deliver one finished utterance to the target tmux session.
    func send(_ text: String, session: String) async {
        guard var req = makeRequest(path: "/say", method: "POST") else { return }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["session": session, "text": text]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                connected = true
                lastError = ""
            } else {
                lastError = "Send failed (HTTP \(code))"
            }
        } catch {
            connected = false
            lastError = "Send failed — \(error.localizedDescription)"
        }
    }

    /// Refresh the list of available tmux sessions for the Settings picker.
    func loadSessions() async {
        guard let req = makeRequest(path: "/sessions") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                lastError = "Couldn't list sessions"
                return
            }
            let decoded = try JSONDecoder().decode(SessionsResponse.self, from: data)
            sessions = decoded.sessions
            connected = true
            lastError = ""
        } catch {
            lastError = "Couldn't list sessions — \(error.localizedDescription)"
        }
    }

    /// Pull the tail of the target tmux pane so the app can show Claude's output.
    func loadPane(session: String, lines: Int = 60) async {
        let encoded = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session
        guard let req = makeRequest(path: "/pane?session=\(encoded)&lines=\(lines)") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(PaneResponse.self, from: data)
            pane = decoded.pane
            connected = true
        } catch {
            // Pane polling is best-effort; don't spam the error banner.
        }
    }
}

private struct SessionsResponse: Decodable {
    let sessions: [String]
}

private struct PaneResponse: Decodable {
    let pane: String
}
