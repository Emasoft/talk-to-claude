import Foundation
import SwiftUI
import Combine

// A self-test for the voice-command pipeline: you read a phrase aloud, the Mac
// transcribes (Whisper) and interprets it WITHOUT injecting into any Claude session
// (dry-run), and we show what Whisper heard, what the interpreter produced, and
// whether it matches the expected result.
//
// The phrase list + expected results come from the SERVER (`GET /test-suite`), which
// computes each expected value by running the real interpreter — so the suite can be
// grown/changed server-side with no app rebuild, and the expected can never drift.

/// One test step. `expect` is the NET text the interpreter should leave on the line
/// (typing-only, so the check is robust to however the VAD splits the utterance).
private struct TestPhrase: Decodable, Identifiable {
    let phrase: String
    let expect: String
    let note: String
    var id: String { phrase }
}

private struct TestSuiteResponse: Decodable { let phrases: [TestPhrase] }

/// Used only until the server's suite loads (or if the Mac is unreachable).
private let FALLBACK_SUITE: [TestPhrase] = [
    TestPhrase(phrase: "command slash", expect: "/", note: "single command"),
    TestPhrase(phrase: "command caps start deploy caps stop", expect: "DEPLOY", note: "CAPS block"),
    TestPhrase(phrase: "command number start one two three number stop", expect: "123", note: "NUMBER block"),
]

@MainActor
final class CommandTester: ObservableObject {
    @Published var recording = false
    @Published var heard = ""     // raw ASR — exactly what Whisper transcribed
    @Published var result = ""    // net interpreted line — what would land in Claude
    @Published var error = ""
    @Published var diagnostic = ""        // audio-health hint from the server (low/noisy/no-audio)
    @Published var diagnosticLevel = ""   // "warn" | "error"
    @Published var voiceProcessing = false  // Apple noise-suppression engaged for this recording
    @Published fileprivate var suite: [TestPhrase] = FALLBACK_SUITE

    private let settings: AppSettings
    private let audio = AudioStreamer()
    private var task: URLSessionWebSocketTask?
    private nonisolated(unsafe) var liveTask: URLSessionWebSocketTask?
    private let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 86_400
        return URLSession(configuration: c)
    }()

    init(settings: AppSettings) { self.settings = settings }

    /// Pull the phrase suite (with server-computed expected results) from the Mac.
    func loadSuite() async {
        guard let url = URL(string: "http://\(settings.macIP):\(settings.portNumber)/test-suite") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TestSuiteResponse.self, from: data),
              !decoded.phrases.isEmpty else { return }
        suite = decoded.phrases
    }

    /// Reset captured text and open a fresh dry-run stream, then start the mic.
    func start() {
        guard task == nil else { return }
        heard = ""; result = ""; error = ""; diagnostic = ""; diagnosticLevel = ""
        guard let url = URL(string: "ws://\(settings.macIP):\(settings.portNumber)/stream") else {
            error = "Bad server URL"; return
        }
        let t = urlSession.webSocketTask(with: url)
        task = t; liveTask = t
        t.resume()
        let cfg: [String: Any] = [
            "token": settings.token,
            "session": "__test__",            // dummy — dry_run skips the target check
            "dry_run": true,                  // transcribe + interpret, NEVER inject
            "prefix_mode": true,              // commands require the "command" prefix
            "auto_send": false,               // no auto Enter — we want the exact result
            "silence_hold": settings.pauseThreshold,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: cfg),
           let s = String(data: d, encoding: .utf8) {
            t.send(.string(s)) { _ in }
        }
        receive()
        audio.onPCM = { [weak self] data in self?.liveTask?.send(.data(data)) { _ in } }
        do { try audio.start(); recording = true; voiceProcessing = audio.voiceProcessing }
        catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        recording = false
        audio.stop()
        liveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive() {
        task?.receive { [weak self] res in
            guard let self else { return }
            switch res {
            case .success(let msg):
                if case .string(let text) = msg {
                    Task { @MainActor in self.handle(text) }
                }
                Task { @MainActor in self.receive() }
            case .failure:
                Task { @MainActor in self.task = nil; self.liveTask = nil; self.recording = false }
            }
        }
    }

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = o["type"] as? String else { return }
        if type == "final" {
            if let raw = o["text"] as? String, !raw.isEmpty {
                heard += (heard.isEmpty ? "" : " ") + raw
            }
            if let line = o["line"] as? String { result = line }   // net text so far
        } else if type == "error" {
            error = (o["error"] as? String) ?? "server error"
        } else if type == "diagnostic" {
            diagnostic = (o["message"] as? String) ?? ""
            diagnosticLevel = (o["level"] as? String) ?? "warn"
        }
    }
}

private struct PhraseResult: Codable {
    var passed: Bool
    var produced: String   // what the interpreter built (compared to expected)
    var heard: String      // raw Whisper transcript (for diagnosis)
}

struct CommandTestView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var tester: CommandTester
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cmdtest_idx") private var idx = 0   // resume position persists across reopen
    @State private var results: [Int: PhraseResult] = [:]   // phrase index → latest attempt
    @State private var attempted: Set<Int> = []      // phrases recorded THIS session
    @State private var showSummary = false
    @State private var autoSummaryShown = false      // auto-open the summary once, when all done
    @State private var confirmInterrupt = false

    init(settings: AppSettings) {
        self.settings = settings
        _tester = StateObject(wrappedValue: CommandTester(settings: settings))
    }

    private var current: TestPhrase? {
        guard !tester.suite.isEmpty else { return nil }
        return tester.suite[min(idx, tester.suite.count - 1)]
    }
    private var hasResult: Bool { !tester.result.isEmpty || !tester.heard.isEmpty }
    private var passed: Bool { current.map { tester.result == $0.expect } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Read the phrase aloud while recording. Nothing is sent to Claude — this only tests whether the commands are recognized.")
                    .font(.callout).foregroundStyle(.secondary)

                if let current {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PHRASE \(idx + 1) of \(tester.suite.count) — \(current.note)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("“\(current.phrase)”")
                            .font(.system(.title2, design: .rounded)).bold()
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    Button {
                        if tester.recording { tester.stop(); recordResult() }   // record on every Stop
                        else { attempted.insert(idx); tester.start() }          // mark this phrase attempted
                    } label: {
                        Label(tester.recording ? "Stop" : "Record & read",
                              systemImage: tester.recording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tester.recording ? .red : .accentColor)

                    if tester.recording {
                        Label(tester.voiceProcessing
                                  ? "Apple noise suppression + voice focus: ON"
                                  : "Noise suppression unavailable on this mic/route",
                              systemImage: tester.voiceProcessing ? "waveform.badge.mic" : "mic.slash")
                            .font(.caption2)
                            .foregroundStyle(tester.voiceProcessing ? .green : .orange)
                    }

                    resultRow("Whisper heard", tester.heard.isEmpty ? "—" : tester.heard)
                    resultRow("Interpreter produced", tester.result.isEmpty ? "—" : tester.result)
                    resultRow("Expected", current.expect)

                    if let r = results[idx], !tester.recording {
                        HStack(spacing: 8) {
                            Image(systemName: r.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            Text(r.passed ? "PASS — command recognized" : "FAIL — see “heard” above")
                                .bold()
                        }
                        .foregroundStyle(r.passed ? .green : .red)
                    }

                    if !tester.diagnostic.isEmpty {
                        Label(tester.diagnostic,
                              systemImage: tester.diagnosticLevel == "error"
                                  ? "exclamationmark.triangle.fill" : "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(tester.diagnosticLevel == "error" ? .red : .orange)
                    }

                    if !tester.error.isEmpty {
                        Text(tester.error).font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Button("Previous") { step(-1) }.disabled(tester.recording || idx == 0)
                        Spacer()
                        Text("\(results.count)/\(tester.suite.count) done · \(results.values.filter { $0.passed }.count) passed")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        // Can't advance until this step has been recorded (passed or failed).
                        Button("Next phrase") { step(1) }
                            .disabled(tester.recording || results[idx] == nil || idx >= tester.suite.count - 1)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .navigationTitle("Command self-test")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // The ONLY way out of the full-screen cover — confirms if a test is running.
                Button("Close") {
                    if tester.recording { confirmInterrupt = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Summary") { recordResult(); showSummary = true }
            }
        }
        .confirmationDialog("Interrupt the test?", isPresented: $confirmInterrupt, titleVisibility: .visible) {
            Button("Interrupt & exit", role: .destructive) { tester.stop(); dismiss() }
            Button("Restart from the beginning") { restart() }
            Button("Keep testing", role: .cancel) { }
        } message: {
            Text("You can resume later from this point, or restart from the beginning.")
        }
        // Dismissing the summary (Done or swipe) closes the whole test, not back to phrase 28.
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) { summaryView }
        .task { loadResults(); await tester.loadSuite() }
        .onChange(of: tester.recording) { _, rec in if !rec { recordResult() } }
        .onChange(of: tester.result) { _, _ in recordResult() }   // record live as results arrive
        .onChange(of: tester.heard) { _, _ in recordResult() }
        .onDisappear { tester.stop() }
    }

    private func recordResult() {
        // Record once the user has actually recorded this phrase — even if the recognizer
        // returned nothing (that's a FAIL, and the step still counts as done/attempted).
        guard let c = current, attempted.contains(idx) else { return }
        results[idx] = PhraseResult(passed: tester.result == c.expect,
                                    produced: tester.result, heard: tester.heard)
        saveResults()
        // All phrases done → pop the summary automatically (once per run).
        if results.count >= tester.suite.count && !tester.suite.isEmpty && !autoSummaryShown {
            autoSummaryShown = true
            showSummary = true
        }
    }

    private func saveResults() {
        let keyed = Dictionary(uniqueKeysWithValues: results.map { (String($0.key), $0.value) })
        if let d = try? JSONEncoder().encode(keyed) {
            UserDefaults.standard.set(d, forKey: "cmdtest_results")
        }
    }

    private func loadResults() {
        guard let d = UserDefaults.standard.data(forKey: "cmdtest_results"),
              let keyed = try? JSONDecoder().decode([String: PhraseResult].self, from: d) else { return }
        results = Dictionary(uniqueKeysWithValues: keyed.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    private func restart() {
        tester.stop()
        idx = 0
        results = [:]
        attempted = []
        autoSummaryShown = false
        saveResults()
        clearStep()
    }

    private func clearStep() {
        tester.heard = ""; tester.result = ""; tester.error = ""
        tester.diagnostic = ""; tester.diagnosticLevel = ""
    }

    private func step(_ d: Int) {
        recordResult()
        tester.stop()
        idx = max(0, min(tester.suite.count - 1, idx + d))
        clearStep()
    }

    private var summaryHeader: String {
        let p = results.values.filter { $0.passed }.count
        return "\(p) / \(results.count) passed"
    }

    private var summaryView: some View {
        NavigationStack {
            List {
                Section {
                    Text(summaryHeader).font(.title3).bold()
                    let untested = tester.suite.count - results.count
                    if untested > 0 {
                        Text("\(untested) not yet tested").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Per phrase") {
                    ForEach(Array(tester.suite.enumerated()), id: \.offset) { i, ph in
                        summaryRow(i, ph)
                    }
                }
            }
            .navigationTitle("Test summary")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSummary = false } }
            }
        }
    }

    private func summaryRow(_ i: Int, _ ph: TestPhrase) -> some View {
        let r = results[i]
        let icon = r == nil ? "circle.dashed" : (r!.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
        let color: Color = r == nil ? .secondary : (r!.passed ? .green : .red)
        // On a fail, char-diff expected vs produced — differing letters in red on both lines.
        let diff: (AttributedString, AttributedString)? =
            (r != nil && !r!.passed) ? lcsDiff(ph.expect, r!.produced) : nil
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(ph.note).font(.callout)
                if let diff {
                    Text(diffLine("want  ", diff.0))
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Text(diffLine("got   ", diff.1))
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    /// A grey label prefix joined to the (red-diffed) text, as one AttributedString.
    private func diffLine(_ label: String, _ diff: AttributedString) -> AttributedString {
        var s = AttributedString(label)
        s.foregroundColor = .secondary
        return s + diff
    }

    /// Char-level LCS diff: returns (expected, produced) as AttributedStrings where the
    /// characters that DON'T line up (the actual differences) are coloured red.
    private func lcsDiff(_ a: String, _ b: String) -> (AttributedString, AttributedString) {
        let ac = Array(a), bc = Array(b)
        let n = ac.count, m = bc.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for ii in stride(from: n - 1, through: 0, by: -1) {
                for jj in stride(from: m - 1, through: 0, by: -1) {
                    dp[ii][jj] = ac[ii] == bc[jj] ? dp[ii + 1][jj + 1] + 1
                        : max(dp[ii + 1][jj], dp[ii][jj + 1])
                }
            }
        }
        var aCommon = Array(repeating: false, count: n)
        var bCommon = Array(repeating: false, count: m)
        var ii = 0, jj = 0
        while ii < n && jj < m {
            if ac[ii] == bc[jj] { aCommon[ii] = true; bCommon[jj] = true; ii += 1; jj += 1 }
            else if dp[ii + 1][jj] >= dp[ii][jj + 1] { ii += 1 } else { jj += 1 }
        }
        func build(_ chars: [Character], _ common: [Bool]) -> AttributedString {
            var s = AttributedString("")
            for (k, ch) in chars.enumerated() {
                var piece = AttributedString(ch == "\n" ? "⏎" : String(ch))
                piece.foregroundColor = common[k] ? .secondary : .red
                s += piece
            }
            return s
        }
        return (build(ac, aCommon), build(bc, bCommon))
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
