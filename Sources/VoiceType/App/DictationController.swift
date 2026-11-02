import Foundation
import AppKit

/// Drives the end-to-end dictation loop:
///
///   hold key down → record + show indicator
///   hold key up   → show spinner, finish capture (post-roll), transcribe
///                   off-thread, insert at caret, restore clipboard, dismiss
///
/// Owns the indicator and inserter, records through the shared audio capture,
/// and submits audio to the shared transcription engine (which serializes jobs
/// itself); the app delegate wires it to the hotkey manager. All methods must
/// be called on the main thread (the hotkey callbacks and timers already hop
/// there).
final class DictationController {
    private let capture: AudioCapture
    private let indicator = IndicatorController()
    private let inserter = TextInserter()
    private let caretLocator = CaretLocator()
    private let engine: TranscriptionEngine
    private let configStore: ConfigStore
    private let soundCues: SoundCues

    /// Ignore taps shorter than this — almost always accidental.
    private let minDuration: Double = 0.3

    private var maxDurationTimer: Timer?
    private var isBusy = false
    /// When the current recording began, to spot accidental taps (the captured
    /// audio is longer than the press: it includes pre- and post-roll).
    private var recordingStartedAt: TimeInterval = 0

    init(engine: TranscriptionEngine, capture: AudioCapture, configStore: ConfigStore) {
        self.engine = engine
        self.capture = capture
        self.configStore = configStore
        self.soundCues = SoundCues(isEnabled: { [weak configStore] in
            configStore?.config.soundCues ?? false
        })
        capture.onLevel = { [weak self] level in self?.indicator.updateLevel(level) }
    }

    private var config: Config { configStore.config }

    // MARK: - Recording entry points (called on main)

    /// Toggle-to-talk: press once to start, press again to stop and transcribe.
    /// Reuses the hold-mode start/stop paths verbatim, so the indicator,
    /// min/max-duration guards, and transcription flow are identical.
    func toggleRecording() {
        if capture.isRecording { stopRecordingAndTranscribe() }
        else { startRecording() }   // startRecording already guards !isBusy
    }

    /// Esc-to-cancel: abort an in-progress recording, discarding the audio.
    /// Nothing is transcribed, inserted, or copied to the clipboard. If a
    /// transcription is already in flight (not recording, `isBusy`),
    /// this is a no-op — cancelling mid-transcription is out of scope.
    func cancelRecording() {
        cancelMaxDurationTimer()
        guard capture.isRecording else { return }   // nothing to cancel
        capture.cancel()         // discards samples
        indicator.dismiss()
        Log.info("Recording cancelled.")
    }

    func startRecording() {
        // The hold hotkey can fire repeatedly while held; only the first starts.
        guard !isBusy, !capture.isRecording else { return }
        do {
            try capture.begin()
            recordingStartedAt = ProcessInfo.processInfo.systemUptime
            Log.info("Recording started.")
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
        guard capture.isRecording else { return }
        let duration = ProcessInfo.processInfo.systemUptime - recordingStartedAt

        guard duration >= minDuration else {
            Log.debug("Ignoring \(String(format: "%.2f", duration))s tap.")
            capture.cancel()
            soundCues.play(.stop)
            indicator.dismiss()
            return
        }

        Log.info("Recording stopped after \(String(format: "%.1f", duration))s; transcribing.")
        indicator.showProcessing()
        isBusy = true
        let trailingSpace = config.trailingSpace

        // The capture finishes after its post-roll, on main. The stop cue waits
        // for it so the cue isn't recorded into the post-roll.
        capture.end { [weak self] samples in
            self?.soundCues.play(.stop)
            self?.transcribe(samples, trailingSpace: trailingSpace)
        }
    }

    private func transcribe(_ samples: [Float], trailingSpace: Bool) {
        // Runs on main; only the `await` leaves it, on the engine's queue.
        Task { @MainActor [weak self, engine] in
            let result: Result<String, Error>
            do { result = .success(try await engine.transcribe(samples).text) }
            catch { result = .failure(error) }
            self?.finishTranscription(result, trailingSpace: trailingSpace)
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

    /// Stops at the configured limit, or at the capture's ceiling when there's
    /// none, transcribing as usual and telling the user why it stopped.
    private func startMaxDurationTimer() {
        let configured = config.maxRecordingSeconds
        let limit = configured > 0 ? configured : AudioCapture.ceilingSeconds
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
            Log.info("Max duration reached; stopping.")
            self?.stopRecordingAndTranscribe()
            let length = DictationLimit.label(limit).replacingOccurrences(of: " ", with: "-")
            Notifier.notify(title: "Dictation stopped",
                            body: "Dictation stopped at the \(length) limit — change it in Settings.")
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
