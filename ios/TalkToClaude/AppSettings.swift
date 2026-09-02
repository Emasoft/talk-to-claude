import Foundation
import Combine

/// Default shared secret, generated at project-creation time. It is baked into
/// BOTH this app and `server/voice_server.py` so the pair works with zero
/// configuration on first run. CHANGE IT in Settings (and pass the same value to
/// the server via CLAUDE_VOICE_TOKEN / --token) — the committed default is public.
let kDefaultToken = "mMfRuOWn9rGWskJOnI4HkrTwReVtblyg"

/// Default Tailscale IPv4 of the Mac running the receiver. Editable in Settings.
let kDefaultMacIP = "100.99.233.43"

/// User-editable configuration, persisted in UserDefaults. Implemented with
/// plain @Published + didSet (rather than @AppStorage) so the object reliably
/// publishes changes to every observing view — @AppStorage only behaves
/// correctly when used directly inside a View.
@MainActor
final class AppSettings: ObservableObject {
    private let store = UserDefaults.standard

    @Published var macIP: String { didSet { store.set(macIP, forKey: "macIP") } }
    @Published var port: String { didSet { store.set(port, forKey: "port") } }
    @Published var token: String { didSet { store.set(token, forKey: "token") } }
    @Published var session: String { didSet { store.set(session, forKey: "session") } }
    /// Pause (seconds) of silence that ends a sentence — sent to the server's VAD.
    @Published var pauseThreshold: Double { didSet { store.set(pauseThreshold, forKey: "pauseThreshold") } }
    /// Submit each sentence automatically (vs. saying "invio" to send).
    @Published var autoSend: Bool { didSet { store.set(autoSend, forKey: "autoSend") } }
    /// Literal-by-default: dictation types verbatim and a command only fires when
    /// preceded by the spoken prefix "command" (vs. command-by-default). Defaults ON —
    /// it's the primary interaction model; turn it off for legacy command-by-default.
    @Published var prefixMode: Bool { didSet { store.set(prefixMode, forKey: "prefixMode") } }
    // Note: transcription cleanup (the local correction LLM) is NON-OPTIONAL and lives
    // entirely on the server — it's always part of the pipeline, so the app carries no
    // toggle or state for it.

    init() {
        // didSet does not fire for assignments made inside init, so these reads
        // do not re-persist the defaults — they only seed the in-memory values.
        macIP = store.string(forKey: "macIP") ?? kDefaultMacIP
        port = store.string(forKey: "port") ?? "8765"
        token = store.string(forKey: "token") ?? kDefaultToken
        session = store.string(forKey: "session") ?? ""   // "" = no Claude chosen yet
        pauseThreshold = store.object(forKey: "pauseThreshold") as? Double ?? 2.0
        autoSend = store.object(forKey: "autoSend") as? Bool ?? false
        prefixMode = store.object(forKey: "prefixMode") as? Bool ?? true
    }

    /// Port parsed to an Int, falling back to the default if the field is junk.
    var portNumber: Int { Int(port) ?? 8765 }
}
