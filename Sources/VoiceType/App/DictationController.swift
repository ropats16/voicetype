import Foundation
import AppKit

/// Drives the end-to-end dictation loop:
///
///   hold key down → record + show indicator
///   hold key up   → stop, show spinner, transcribe off-thread,
///                   insert at caret, restore clipboard, dismiss
///
/// Owns the recorder, indicator, inserter, and transcriber; the app delegate
/// wires it to the hotkey manager. All methods must be called on the main
/// thread (the hotkey callbacks and timers already hop there).
final class DictationController {
    private let recorder = AudioRecorder()
    private let indicator = IndicatorController()
    private let inserter = TextInserter()
    private let transcriber: Transcriber
    private let configStore: ConfigStore

    /// Ignore taps shorter than this — almost always accidental.
    private let minDuration: Double = 0.3

    private var maxDurationTimer: Timer?
    private let work = DispatchQueue(label: "com.local.VoiceType.transcribe", qos: .userInitiated)
    private var isBusy = false

    init(transcriber: Transcriber, configStore: ConfigStore) {
        self.transcriber = transcriber
        self.configStore = configStore
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.indicator.updateLevel(level) }
        }
    }

    private var config: Config { configStore.config }

    // MARK: - Hold-to-talk entry points (called on main)

    func startRecording() {
        guard !isBusy else { return }
        do {
            try recorder.start()
            indicator.showRecording()
            startMaxDurationTimer()
        } catch {
            Log.error("Recording failed to start: \(error.localizedDescription)")
            notify("Couldn't start recording", error.localizedDescription)
            indicator.dismiss()
        }
    }

    func stopRecordingAndTranscribe() {
        cancelMaxDurationTimer()
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate

        guard duration >= minDuration else {
            Log.debug("Ignoring \(String(format: "%.2f", duration))s tap.")
            indicator.dismiss()
            return
        }

        indicator.showProcessing()
        isBusy = true
        let trailingSpace = config.trailingSpace

        work.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.transcriber.transcribe(samples: samples) }
            DispatchQueue.main.async {
                self.finishTranscription(result, trailingSpace: trailingSpace)
            }
        }
    }

    private func finishTranscription(_ result: Result<String, Error>, trailingSpace: Bool) {
        isBusy = false
        indicator.dismiss()
        switch result {
        case .success(let raw):
            let text = clean(raw, trailingSpace: trailingSpace)
            guard !text.isEmpty else {
                Log.info("Transcription was empty.")
                return
            }
            inserter.insert(text)
        case .failure(let error):
            Log.error("Transcription failed: \(error.localizedDescription)")
            notify("Transcription failed", error.localizedDescription)
        }
    }

    // MARK: - Max duration auto-stop

    private func startMaxDurationTimer() {
        let max = config.maxRecordingSeconds
        guard max > 0 else { return }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: max, repeats: false) { [weak self] _ in
            Log.info("Max duration reached; stopping.")
            self?.stopRecordingAndTranscribe()
        }
    }

    private func cancelMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: - Text cleanup

    private func clean(_ raw: String, trailingSpace: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // whisper.cpp sometimes emits bracketed non-speech tags like [BLANK_AUDIO].
        if text.hasPrefix("[") && text.hasSuffix("]") { text = "" }
        if !text.isEmpty && trailingSpace { text += " " }
        return text
    }

    private func notify(_ title: String, _ body: String) {
        // Lightweight surfacing for Phase 1; Phase 3 adds richer error UX.
        Log.error("\(title): \(body)")
    }
}
