import SwiftUI

struct ContentView: View {
    @StateObject private var settings: AppSettings
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var claude: ClaudeClient

    @State private var showSettings = false
    @State private var sentLog: [String] = []

    private let paneTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init() {
        // ClaudeClient needs the settings instance, so build both here and have
        // the two StateObjects share one AppSettings.
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _claude = StateObject(wrappedValue: ClaudeClient(settings: s))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusBar
                transcriptCard
                micControls
                if !sentLog.isEmpty { sentLogCard }
                if settings.showReplies { paneCard }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Talk to Claude")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings, claude: claude)
            }
        }
        .onAppear(perform: configure)
        .onReceive(paneTimer) { _ in
            guard settings.showReplies else { return }
            Task { await claude.loadPane(session: settings.session) }
        }
        .onChange(of: settings.pauseThreshold) { _, newValue in speech.pauseThreshold = newValue }
        .onChange(of: settings.autoSend) { _, newValue in speech.autoSend = newValue }
    }

    // MARK: - Setup

    private func configure() {
        speech.requestAuthorization()
        speech.pauseThreshold = settings.pauseThreshold
        speech.autoSend = settings.autoSend
        speech.onUtterance = { text in
            sentLog.insert(text, at: 0)
            if sentLog.count > 30 { sentLog.removeLast() }
            Task { await claude.send(text, session: settings.session) }
        }
        Task { await claude.checkHealth() }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(claude.connected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(claude.connected ? "Connected to \(settings.macIP)" : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("▸ \(settings.session)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(speech.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(speech.transcript.isEmpty ? "…" : speech.transcript)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var micControls: some View {
        HStack(spacing: 24) {
            Button(action: speech.toggle) {
                ZStack {
                    Circle()
                        .fill(speech.isListening ? Color.red : Color.accentColor)
                        .frame(width: 96, height: 96)
                        .shadow(radius: speech.isListening ? 12 : 4)
                    Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .symbolEffect(.variableColor, isActive: speech.isListening)

            if speech.isListening {
                Button(action: speech.flush) {
                    VStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.title2)
                        Text("Send").font(.caption)
                    }
                    .frame(width: 72, height: 72)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sentLogCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sentLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var paneCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude output ▸ \(settings.session)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(claude.pane.isEmpty ? "(no output yet)" : claude.pane)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.green)
    }
}

#Preview {
    ContentView()
}
