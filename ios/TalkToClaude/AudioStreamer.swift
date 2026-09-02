import Foundation
import AVFoundation

/// Captures microphone audio continuously and emits 16 kHz mono **PCM16** frames.
///
/// There is NO on-device recognition here — raw audio is streamed to the Mac,
/// which runs VAD + Whisper. This runs FOREGROUND-ONLY (the caller stops it on
/// `scenePhase == .background`), and uses `.playAndRecord` + `.duckOthers` so
/// other apps' audio is lowered while recording and fully restored on stop.
final class AudioStreamer {
    /// Called (on the audio thread) with little-endian PCM16 bytes at 16 kHz mono.
    var onPCM: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private(set) var isRunning = false
    /// Whether Apple's Voice Processing I/O (ambient-noise suppression + echo
    /// cancellation + voice-band AGC) actually engaged on this device/route.
    private(set) var voiceProcessing = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // .duckOthers drops other apps' volume low while we record (so the
            // user's voice dominates the mic, instead of the other panel's audio),
            // then restores it when we stop — without freezing them. .voiceChat
            // mode adds noise suppression / AGC on top. The mic still physically
            // hears whatever the speaker plays, so for a truly clean signal use
            // headphones (the other audio then never reaches the speaker/mic).
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            // Apple's Voice Processing I/O — the SDK's ambient-noise suppression + echo
            // cancellation + voice-band focus, tuned for the human voice. Don't swallow a
            // failure: record whether it actually engaged so the UI can show it. Pairs with
            // the .voiceChat session mode set above (both route through Apple's VPIO unit).
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled = true        // auto-gain on the voice band
                voiceProcessing = input.isVoiceProcessingEnabled
            } catch {
                voiceProcessing = false
                NSLog("AudioStreamer: voice processing unavailable — %@", error.localizedDescription)
            }
            let hwFormat = input.outputFormat(forBus: 0)
            guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw NSError(domain: "AudioStreamer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Can't convert \(Int(hwFormat.sampleRate)) Hz mic input to 16 kHz",
                ])
            }
            converter = conv
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            // Never leave the session active without actually recording — that
            // would keep other apps frozen even though we're "not recording".
            teardown()
            throw error
        }
    }

    func stop() {
        teardown()
    }

    /// Fully release audio so other apps regain playback. Idempotent — safe to
    /// call even if we never finished starting.
    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        onPCM?(Data(bytes: channel[0], count: byteCount))
    }
}
