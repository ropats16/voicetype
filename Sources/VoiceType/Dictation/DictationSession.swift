import Foundation

/// One dictation at a time, as an explicit state machine:
///
///     idle → recording → transcribing → delivering → idle
///
/// driven by the user's intents (hold down/up, toggle, cancel) and by its own
/// events (mic started or failed, max duration elapsed, post-roll captured,
/// transcription finished). Every transition rule lives here; the mic, the
/// engine, delivery, feedback (indicator, cues, notifications), history and
/// time are ports (see `DictationPorts.swift`).
///
/// Rules worth knowing:
/// - Starting while not idle is ignored: one start cue, one timer, one capture.
/// - Each recording gets an id; callbacks (mic start, timer, post-roll,
///   transcript) for any other recording are ignored, so a late one can't
///   stop, fail or deliver the current one.
/// - Hold-up or toggle stops any recording, even one whose mic is still
///   starting; a stop shorter than `minSeconds` is an accidental tap and is
///   dropped (stop cue, no transcription).
/// - Toggle, hold and cancel do nothing while transcribing or delivering.
/// - Only non-empty, non-tag-only text is delivered, and each delivery is
///   reported once to the history.
///
/// Main-thread only: call `handle` on main; ports call back on main.
final class DictationSession {
    enum Phase: Equatable { case idle, recording, transcribing, delivering }

    /// What the user asked for, from the hotkeys.
    enum Intent: Equatable { case holdDown, holdUp, toggle, cancel }

    /// Intents plus the session's own events, each tagged with the recording
    /// it belongs to.
    private enum Event {
        case intent(Intent)
        case micStarted(id: Int, Error?)
        case maxDurationElapsed(id: Int)
        case captured(id: Int, samples: [Float])
        case transcribed(id: Int, Result<String, Error>)
    }

    private enum State {
        case idle
        case recording(id: Int, startedAt: TimeInterval, limit: TimeInterval)
        /// Stopped; waiting for the capture's post-roll.
        case finishingCapture(id: Int, trailingSpace: Bool)
        case transcribing(id: Int, trailingSpace: Bool)
        case delivering
    }

    private let capture: DictationCapture
    private let engine: DictationEngine
    private let delivery: DictationDelivery
    private let feedback: DictationFeedback
    private let history: DictationHistory
    private let clock: DictationClock
    private let settings: () -> DictationSettings

    private var state: State = .idle
    /// The running recording's max-duration timer; at most one exists.
    private var timer: DictationTimer?
    private var lastId = 0

    var phase: Phase {
        switch state {
        case .idle: return .idle
        case .recording: return .recording
        case .finishingCapture, .transcribing: return .transcribing
        case .delivering: return .delivering
        }
    }

    /// `settings` is read live: `maxSeconds` at start, `minSeconds` and
    /// `trailingSpace` at stop.
    init(capture: DictationCapture, engine: DictationEngine, delivery: DictationDelivery,
         feedback: DictationFeedback, history: DictationHistory = NoDictationHistory(),
         clock: DictationClock = SystemDictationClock(),
         settings: @escaping () -> DictationSettings) {
        self.capture = capture
        self.engine = engine
        self.delivery = delivery
        self.feedback = feedback
        self.history = history
        self.clock = clock
        self.settings = settings
        capture.onLevel = { [weak self] level in
            guard let self, case .recording = state else { return }
            feedback.showLevel(level)
        }
    }

    func handle(_ intent: Intent) { handle(.intent(intent)) }

    // MARK: - Transitions

    private func handle(_ event: Event) {
        switch (state, event) {
        // idle
        case (.idle, .intent(.holdDown)), (.idle, .intent(.toggle)):
            start()

        // recording
        case (.recording(let id, let startedAt, _), .intent(.holdUp)),
             (.recording(let id, let startedAt, _), .intent(.toggle)):
            stop(id: id, startedAt: startedAt)

        case (.recording(let id, let startedAt, let limit), .maxDurationElapsed(let timed)) where timed == id:
            Log.info("Max duration reached; stopping.")
            stop(id: id, startedAt: startedAt)
            let length = DictationLimit.label(limit).replacingOccurrences(of: " ", with: "-")
            feedback.notify(title: "Dictation stopped",
                            body: "Dictation stopped at the \(length) limit — change it in Settings.")

        case (.recording, .intent(.cancel)):
            Log.info("Recording cancelled.")
            capture.cancel()
            end()

        case (.recording(let id, _, _), .micStarted(let started, let error?)) where started == id,
             (.finishingCapture(let id, _), .micStarted(let started, let error?)) where started == id:
            // The capture is over; its `end`, if any, brings no samples.
            Log.error("Couldn't start recording: \(error.localizedDescription)")
            feedback.notify(title: "Couldn't start recording", body: error.localizedDescription)
            end()

        // transcribing
        case (.finishingCapture(let id, let trailingSpace), .captured(let finished, let samples)) where finished == id:
            // Only now, so the cue isn't recorded into the post-roll.
            feedback.play(.stop)
            guard !samples.isEmpty else {
                Log.info("Nothing was recorded.")
                return end()
            }
            state = .transcribing(id: id, trailingSpace: trailingSpace)
            engine.transcribe(samples) { [weak self] result in
                self?.handle(.transcribed(id: id, result))
            }

        case (.transcribing(let id, let trailingSpace), .transcribed(let finished, let result)) where finished == id:
            feedback.dismiss()
            state = .idle
            switch result {
            case .success(let raw):
                deliver(TranscriptCleanup.clean(raw, trailingSpace: trailingSpace))
            case .failure(let error):
                Log.error("Transcription failed: \(error.localizedDescription)")
                feedback.notify(title: "Transcription failed", body: error.localizedDescription)
            }

        // Everything else: repeats (auto-repeat key down), intents while busy,
        // and events of recordings that are already over.
        default:
            break
        }
    }

    // MARK: - Actions

    private func start() {
        lastId += 1
        let id = lastId
        let configured = settings().maxSeconds
        let limit = configured > 0 ? configured : AudioCapture.ceilingSeconds
        state = .recording(id: id, startedAt: clock.now, limit: limit)
        Log.info("Recording started.")
        // Reload an idle-unloaded model while the user talks, and keep it
        // loaded until the job or `endPrewarm()`.
        engine.prewarm()
        feedback.showRecording()
        feedback.play(.start)
        timer = clock.schedule(after: limit) { [weak self] in
            self?.handle(.maxDurationElapsed(id: id))
        }
        // Last: a capture that fails at once leaves nothing else to undo.
        capture.begin { [weak self] error in
            self?.handle(.micStarted(id: id, error))
        }
    }

    private func stop(id: Int, startedAt: TimeInterval) {
        cancelTimer()
        let duration = clock.now - startedAt
        let current = settings()
        guard duration >= current.minSeconds else {
            Log.debug("Ignoring \(String(format: "%.2f", duration))s tap.")
            capture.cancel()
            feedback.play(.stop)
            return end()
        }
        Log.info("Recording stopped after \(String(format: "%.1f", duration))s; transcribing.")
        feedback.showProcessing()
        state = .finishingCapture(id: id, trailingSpace: current.trailingSpace)
        capture.end { [weak self] samples in
            self?.handle(.captured(id: id, samples: samples))
        }
    }

    /// Ends a dictation that won't be transcribed.
    private func end() {
        cancelTimer()
        engine.endPrewarm()
        feedback.dismiss()
        state = .idle
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            Log.info("Transcription was empty.")
            return
        }
        state = .delivering
        let outcome = delivery.deliver(text)
        if outcome == .copied {
            Log.info("Focused element isn't editable; copied instead of pasting.")
            feedback.notify(title: "Dictation copied", body: "No text field is focused — paste with ⌘V.")
        }
        history.delivered(text, outcome: outcome)
        state = .idle
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
