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
    private let caretLocator = CaretLocator()
    private let transcriber: Transcriber
    private let configStore: ConfigStore
    private let soundCues: SoundCues

    /// Ignore taps shorter than this — almost always accidental.
    private let minDuration: Double = 0.3

    private var maxDurationTimer: Timer?
    private let work = DispatchQueue(label: "com.local.VoiceType.transcribe", qos: .userInitiated)
    private var isBusy = false

    init(transcriber: Transcriber, configStore: ConfigStore) {
        self.transcriber = transcriber
        self.configStore = configStore
        self.soundCues = SoundCues(isEnabled: { [weak configStore] in
            configStore?.config.soundCues ?? false
        })
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.indicator.updateLevel(level) }
        }
    }

    private var config: Config { configStore.config }

    // MARK: - Recording entry points (called on main)

    /// Toggle-to-talk: press once to start, press again to stop and transcribe.
    /// Reuses the hold-mode start/stop paths verbatim, so the indicator,
    /// min/max-duration guards, and transcription flow are identical.
    func toggleRecording() {
        if recorder.isRecording { stopRecordingAndTranscribe() }
        else { startRecording() }   // startRecording already guards !isBusy
    }

    /// Esc-to-cancel: abort an in-progress recording, discarding the audio.
    /// Nothing is transcribed, inserted, or copied to the clipboard. If a
    /// transcription is already in flight (`isRecording == false`, `isBusy`),
    /// this is a no-op — cancelling mid-transcription is out of scope.
    func cancelRecording() {
        cancelMaxDurationTimer()
        guard recorder.isRecording else { return }   // nothing to cancel
        recorder.cancel()        // stops + discards samples
        indicator.dismiss()
        Log.info("Recording cancelled.")
    }

    func startRecording() {
        guard !isBusy else { return }
        do {
            // Live-read config so a mic change in Settings takes effect next recording.
            recorder.preferredDeviceUID = config.microphoneUID
            try recorder.start()
            indicator.showRecording()
            soundCues.play(.start)
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
        soundCues.play(.stop)
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
            switch caretLocator.focusVerdict() {
            case .editable, .unknown:
                // `.unknown` = the app exposed no focused element (e.g. an
                // Electron app whose AX tree isn't up yet). Paste anyway rather
                // than silently divert to the clipboard — best-effort ⌘V is the
                // behaviour users expect and it works in every app we've seen.
                inserter.insert(text)
            case .notEditable:
                Log.info("Focused element isn't editable; copying instead of pasting.")
                inserter.copyOnly(text)
                Notifier.notify(title: "Dictation copied", body: "No text field is focused — paste with ⌘V.")
            }
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
        Log.error("\(title): \(body)")
        Notifier.notify(title: title, body: body)
    }
}
