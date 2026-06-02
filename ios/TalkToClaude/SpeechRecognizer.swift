import Foundation
import AVFoundation
import Speech
import UIKit

/// Continuous, on-device speech-to-text built on SFSpeechRecognizer + AVAudioEngine.
///
/// Design notes:
/// - Audio never leaves the phone: `requiresOnDeviceRecognition` is enabled when
///   the locale supports it.
/// - "Continuous" dictation is achieved by running one recognition request and
///   segmenting utterances ourselves: a pause timer resets on every transcript
///   change, and when speech stops for `pauseThreshold` seconds the current
///   transcript is treated as a finished utterance (auto-send), after which a
///   fresh request is started so the next utterance begins clean.
/// - SFSpeechRecognizer has an internal ~1 minute audio limit and will end a
///   request with an error; we transparently restart while still listening.
/// - A monotonically increasing `generation` token tags each recognition task so
///   the cancellation error from a *previous* request can't trigger a restart
///   loop — only callbacks from the current generation are honored.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var status: String = "Tap the mic to start"
    @Published var authorized: Bool = false

    /// Invoked with a trimmed, non-empty utterance when speech pauses (auto mode)
    /// or when `flush()` is called (manual mode).
    var onUtterance: ((String) -> Void)?

    /// Seconds of silence that finalize an utterance (auto-send mode only).
    var pauseThreshold: TimeInterval = 1.2
    /// When false, utterances are only sent via `flush()` (push-to-talk / Send).
    var autoSend: Bool = true

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pauseTimer: Timer?
    private var lastSentText: String = ""
    private var generation = 0
    private var isRestarting = false

    // MARK: - Authorization

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { speechAuth in
            AVAudioApplication.requestRecordPermission { micGranted in
                Task { @MainActor in
                    let speechOK = (speechAuth == .authorized)
                    self.authorized = speechOK && micGranted
                    if !speechOK {
                        self.status = "Speech recognition permission denied"
                    } else if !micGranted {
                        self.status = "Microphone permission denied"
                    } else if self.recognizer == nil {
                        self.status = "Speech recognition unavailable for this locale"
                    } else {
                        self.status = "Ready — tap the mic to start"
                    }
                }
            }
        }
    }

    // MARK: - Control

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        guard authorized else {
            status = "Not authorized — check Settings ▸ Privacy"
            return
        }
        do {
            try beginSession()
            isListening = true
            status = "Listening…"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        isListening = false
        pauseTimer?.invalidate(); pauseTimer = nil
        generation += 1 // invalidate any in-flight callbacks
        request?.endAudio()
        task?.cancel(); task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
        transcript = ""
        lastSentText = ""
        if status == "Listening…" { status = "Stopped" }
    }

    /// Force-send the current transcript right now (manual / push-to-talk).
    func flush() {
        finalizeUtterance()
    }

    // MARK: - Recognition plumbing

    private func beginSession() throws {
        generation += 1
        let gen = generation

        task?.cancel()
        task = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if let rec = recognizer, rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        guard let rec = recognizer, rec.isAvailable else {
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable"])
        }

        transcript = ""
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(generation: gen, result: result, error: error)
            }
        }
    }

    private func handle(generation gen: Int,
                        result: SFSpeechRecognitionResult?,
                        error: Error?) {
        // Drop stale callbacks from a request we've since replaced/cancelled.
        guard gen == generation else { return }

        if let result = result {
            transcript = result.bestTranscription.formattedString
            if autoSend {
                resetPauseTimer()
            }
            if result.isFinal {
                finalizeUtterance()
                return
            }
        }

        if error != nil {
            // The request ended (commonly the ~1 minute audio limit). Restart so
            // listening feels continuous; otherwise just report we stopped.
            if isListening {
                restart()
            } else {
                status = "Stopped"
            }
        }
    }

    private func resetPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: pauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finalizeUtterance() }
        }
    }

    private func finalizeUtterance() {
        pauseTimer?.invalidate(); pauseTimer = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastSentText else {
            if isListening { restart() }
            return
        }
        lastSentText = text
        onUtterance?(text)
        if isListening { restart() }
    }

    private func restart() {
        guard isListening, !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        do {
            try beginSession()
        } catch {
            status = "Restart failed: \(error.localizedDescription)"
            stop()
        }
    }
}
