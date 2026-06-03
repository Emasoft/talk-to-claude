import Foundation
import Combine

/// Settings-only HTTP client for the Mac receiver (`server/voice_server.py`):
/// the "Test connection" probe and the tmux-session list. The voice path itself
/// is the WebSocket in `VoiceStream`. Plain HTTP — Tailscale (WireGuard) encrypts
/// every packet, and the bearer token authorizes the call.
@MainActor
final class ClaudeClient: ObservableObject {
    @Published var connected: Bool = false
    @Published var lastError: String = ""
    @Published var sessions: [String] = []

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

}

private struct SessionsResponse: Decodable {
    let sessions: [String]
}
