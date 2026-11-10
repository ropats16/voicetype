import XCTest
@testable import VoiceType

/// `DictationSession` driven through its intents, with fake ports and a manual
/// clock: no mic, no model, no AppKit.
final class DictationSessionTests: XCTestCase {

    // MARK: - Fakes

    private final class ManualClock: DictationClock {
        final class Pending: DictationTimer {
            let due: TimeInterval
            let action: () -> Void
            var isCancelled = false
            var hasFired = false
            init(due: TimeInterval, action: @escaping () -> Void) { self.due = due; self.action = action }
            func cancel() { isCancelled = true }
        }

        var now: TimeInterval = 1_000
        private(set) var timers: [Pending] = []

        /// Timers neither fired nor cancelled.
        var live: [Pending] { timers.filter { !$0.isCancelled && !$0.hasFired } }

        func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> DictationTimer {
            let timer = Pending(due: now + seconds, action: action)
            timers.append(timer)
            return timer
        }

        /// Moves time on, firing every live timer that comes due.
        func advance(by seconds: TimeInterval) {
            now += seconds
            for timer in timers where !timer.isCancelled && !timer.hasFired && timer.due <= now {
                timer.hasFired = true
                timer.action()
            }
        }
    }

    private final class FakeCapture: DictationCapture {
        var onLevel: ((Float) -> Void)?
        private(set) var begins: [(Error?) -> Void] = []
        private(set) var ends: [([Float]) -> Void] = []
        private(set) var cancels = 0

        func begin(_ started: @escaping (Error?) -> Void) { begins.append(started) }
        func end(_ completion: @escaping ([Float]) -> Void) { ends.append(completion) }
        func cancel() { cancels += 1 }

        /// Reports the `index`th begin as started or failed.
        func started(_ index: Int = 0, error: Error? = nil) {
            guard begins.indices.contains(index) else { return XCTFail("No begin #\(index)") }
            begins[index](error)
        }
        /// Finishes the latest end (post-roll in) with `samples`.
        func finishEnd(_ samples: [Float] = [0.1, 0.2]) {
            guard let end = ends.last else { return XCTFail("No end to finish") }
            end(samples)
        }
    }

    private final class FakeEngine: DictationEngine {
        private(set) var prewarms = 0
        private(set) var endPrewarms = 0
        private(set) var jobs: [[Float]] = []
        private var completions: [(Result<String, Error>) -> Void] = []

        func prewarm() { prewarms += 1 }
        func endPrewarm() { endPrewarms += 1 }
        func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
            jobs.append(samples)
            completions.append(completion)
        }

        /// Completes the latest job.
        func finish(_ result: Result<String, Error>) {
            guard let completion = completions.last else { return XCTFail("No job to finish") }
            completion(result)
        }
        func finish(text: String) { finish(.success(text)) }
    }

    private final class FakeDelivery: DictationDelivery {
        var outcome: DeliveryOutcome = .pasted
        private(set) var delivered: [String] = []
        func deliver(_ text: String) -> DeliveryOutcome {
            delivered.append(text)
            return outcome
        }
    }

    private final class FakeFeedback: DictationFeedback {
        enum Event: Equatable {
            case showRecording, showProcessing, dismiss
            case level(Float)
            case cue(SoundCue)
            case notify(String, String)
        }
        private(set) var events: [Event] = []

        func showRecording() { events.append(.showRecording) }
        func showLevel(_ level: Float) { events.append(.level(level)) }
        func showProcessing() { events.append(.showProcessing) }
        func dismiss() { events.append(.dismiss) }
        func play(_ cue: SoundCue) { events.append(.cue(cue)) }
        func notify(title: String, body: String) { events.append(.notify(title, body)) }

        var cues: [SoundCue] { events.compactMap { if case .cue(let c) = $0 { return c } else { return nil } } }
        var notifications: [String] { events.compactMap { if case .notify(let t, _) = $0 { return t } else { return nil } } }
    }

    private final class FakeHistory: DictationHistory {
        struct Entry: Equatable { let text: String; let outcome: DeliveryOutcome }
        private(set) var entries: [Entry] = []
        func delivered(_ text: String, outcome: DeliveryOutcome) {
            entries.append(Entry(text: text, outcome: outcome))
        }
    }

    private struct FakeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Fixture

    private var clock: ManualClock!
    private var capture: FakeCapture!
    private var engine: FakeEngine!
    private var delivery: FakeDelivery!
    private var feedback: FakeFeedback!
    private var history: FakeHistory!
    private var settings: DictationSettings!
    private var session: DictationSession!

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        capture = FakeCapture()
        engine = FakeEngine()
        delivery = FakeDelivery()
        feedback = FakeFeedback()
        history = FakeHistory()
        settings = DictationSettings(minSeconds: 0.3, maxSeconds: 600, trailingSpace: false)
        session = DictationSession(
            capture: capture, engine: engine, delivery: delivery, feedback: feedback,
            history: history, clock: clock, settings: { [unowned self] in settings }
        )
    }

    // MARK: - Starting

    func testHoldDownStartsOneRecording() {
        session.handle(.holdDown)

        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(engine.prewarms, 1)
        XCTAssertEqual(capture.begins.count, 1)
        XCTAssertEqual(feedback.events, [.showRecording, .cue(.start)])
        XCTAssertEqual(clock.live.count, 1)
        XCTAssertEqual(clock.live.first?.due, 1_000 + 600)
    }

    func testRepeatedStartGivesOneCueAndOneTimer() {
        session.handle(.holdDown)
        session.handle(.holdDown)   // key auto-repeat
        session.handle(.holdDown)

        XCTAssertEqual(feedback.cues, [.start])
        XCTAssertEqual(clock.timers.count, 1)
        XCTAssertEqual(capture.begins.count, 1)
        XCTAssertEqual(engine.prewarms, 1)
    }

    // MARK: - Hold to talk, end to end

    /// Holds for 2 s, releases, finishes the post-roll and the transcription.
    private func dictate(_ text: String, via start: DictationSession.Intent = .holdDown,
                         stop: DictationSession.Intent = .holdUp) {
        session.handle(start)
        capture.started()
        clock.advance(by: 2)
        session.handle(stop)
        capture.finishEnd()
        engine.finish(text: text)
    }

    func testHoldThenReleaseTranscribesAndDelivers() {
        session.handle(.holdDown)
        capture.started()
        clock.advance(by: 2)
        session.handle(.holdUp)

        XCTAssertEqual(session.phase, .transcribing)
        XCTAssertEqual(feedback.events.last, .showProcessing)
        XCTAssertEqual(capture.ends.count, 1)
        XCTAssertEqual(feedback.cues, [.start], "Stop cue waits for the post-roll")
        XCTAssertTrue(engine.jobs.isEmpty)

        capture.finishEnd([0.5, 0.25])
        XCTAssertEqual(feedback.cues, [.start, .stop])
        XCTAssertEqual(engine.jobs, [[0.5, 0.25]])
        XCTAssertEqual(session.phase, .transcribing)

        engine.finish(text: " Hello world. ")
        XCTAssertEqual(delivery.delivered, ["Hello world."])
        XCTAssertEqual(history.entries, [.init(text: "Hello world.", outcome: .pasted)])
        XCTAssertEqual(feedback.events.last, .dismiss)
        XCTAssertEqual(session.phase, .idle)
    }

    func testReleaseCancelsMaxDurationTimer() {
        session.handle(.holdDown)
        clock.advance(by: 2)
        session.handle(.holdUp)
        XCTAssertTrue(clock.live.isEmpty)
    }

    func testIndicatorDismissedBeforeDelivery() {
        final class OrderingDelivery: DictationDelivery {
            var feedback: FakeFeedback!
            var eventsAtDelivery: [FakeFeedback.Event] = []
            func deliver(_ text: String) -> DeliveryOutcome {
                eventsAtDelivery = feedback.events
                return .pasted
            }
        }
        let ordering = OrderingDelivery()
        ordering.feedback = feedback
        session = DictationSession(capture: capture, engine: engine, delivery: ordering,
                                   feedback: feedback, history: history, clock: clock,
                                   settings: { [unowned self] in settings })
        dictate("hi")
        XCTAssertEqual(ordering.eventsAtDelivery.last, .dismiss)
    }

    func testCopiedOutcomeTellsUserToPaste() {
        delivery.outcome = .copied
        dictate("hello")
        XCTAssertEqual(delivery.delivered, ["hello"])
        XCTAssertEqual(history.entries, [.init(text: "hello", outcome: .copied)])
        XCTAssertEqual(feedback.events.last,
                       .notify("Dictation copied", "No text field is focused — paste with ⌘V."))
    }

    func testPastedOutcomeIsSilent() {
        dictate("hello")
        XCTAssertTrue(feedback.notifications.isEmpty)
    }

    func testTranscriptionFailureNotifiesAndDeliversNothing() {
        session.handle(.holdDown)
        clock.advance(by: 2)
        session.handle(.holdUp)
        capture.finishEnd()
        engine.finish(.failure(FakeError("model gone")))

        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(Array(feedback.events.suffix(2)),
                       [.dismiss, .notify("Transcription failed", "model gone")])
        XCTAssertEqual(session.phase, .idle)
    }

    func testCanDictateAgainAfterEachEnding() {
        dictate("one")
        dictate("[BLANK_AUDIO]")
        session.handle(.holdDown); clock.advance(by: 2); session.handle(.holdUp)
        capture.finishEnd(); engine.finish(.failure(FakeError("x")))
        session.handle(.holdDown); session.handle(.cancel)                              // cancelled
        session.handle(.holdDown); session.handle(.holdUp)                              // tap
        session.handle(.holdDown); capture.started(capture.begins.count - 1, error: FakeError("x"))
        session.handle(.holdUp)
        dictate("two")
        XCTAssertEqual(delivery.delivered, ["one", "two"])
        XCTAssertEqual(feedback.cues.filter { $0 == .start }.count, 7)
        XCTAssertTrue(clock.live.isEmpty)
    }

    // MARK: - Short taps

    func testTooShortTapIsDismissed() {
        session.handle(.holdDown)
        clock.advance(by: 0.29)
        session.handle(.holdUp)

        XCTAssertEqual(capture.cancels, 1)
        XCTAssertTrue(capture.ends.isEmpty)
        XCTAssertEqual(engine.endPrewarms, 1)
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertEqual(feedback.events, [.showRecording, .cue(.start), .cue(.stop), .dismiss])
        XCTAssertTrue(clock.live.isEmpty)
        XCTAssertEqual(session.phase, .idle)
    }

    func testTapJustOverMinDurationIsTranscribed() {
        session.handle(.holdDown)
        clock.advance(by: 0.31)
        session.handle(.holdUp)
        XCTAssertEqual(capture.cancels, 0)
        XCTAssertEqual(session.phase, .transcribing)
    }

    func testMinDurationComesFromSettings() {
        settings.minSeconds = 1
        session.handle(.holdDown)
        clock.advance(by: 0.5)
        session.handle(.holdUp)
        XCTAssertEqual(capture.cancels, 1)
    }

    // MARK: - Cancel

    func testCancelDuringRecordingDeliversNothing() {
        session.handle(.holdDown)
        capture.started()
        clock.advance(by: 5)
        session.handle(.cancel)

        XCTAssertEqual(capture.cancels, 1)
        XCTAssertTrue(capture.ends.isEmpty)
        XCTAssertEqual(engine.endPrewarms, 1)
        XCTAssertTrue(clock.live.isEmpty)
        XCTAssertEqual(feedback.events, [.showRecording, .cue(.start), .dismiss])
        XCTAssertEqual(session.phase, .idle)

        session.handle(.holdUp)   // the hold key, released after Esc
        XCTAssertTrue(capture.ends.isEmpty)
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testCancelWhileIdleOrTranscribingDoesNothing() {
        session.handle(.cancel)
        XCTAssertTrue(feedback.events.isEmpty)

        session.handle(.holdDown); clock.advance(by: 2); session.handle(.holdUp)
        session.handle(.cancel)
        XCTAssertEqual(capture.cancels, 0)
        capture.finishEnd()
        session.handle(.cancel)
        engine.finish(text: "kept")
        XCTAssertEqual(delivery.delivered, ["kept"])
    }

    // MARK: - Toggle to talk

    func testToggleStartsThenStops() {
        dictate("toggled", via: .toggle, stop: .toggle)
        XCTAssertEqual(delivery.delivered, ["toggled"])
        XCTAssertEqual(feedback.cues, [.start, .stop])
    }

    func testToggleIgnoredWhileTranscribing() {
        session.handle(.toggle); clock.advance(by: 2); session.handle(.toggle)

        session.handle(.toggle)   // waiting for post-roll
        capture.finishEnd()
        session.handle(.toggle)   // engine running
        session.handle(.holdDown)

        XCTAssertEqual(capture.begins.count, 1)
        XCTAssertEqual(feedback.cues, [.start, .stop])
        XCTAssertEqual(session.phase, .transcribing)
        engine.finish(text: "done")
        XCTAssertEqual(delivery.delivered, ["done"])
        XCTAssertEqual(session.phase, .idle)
    }

    func testToggleIgnoredWhileDelivering() {
        final class ReentrantDelivery: DictationDelivery {
            weak var session: DictationSession?
            var phaseSeen: DictationSession.Phase?
            func deliver(_ text: String) -> DeliveryOutcome {
                phaseSeen = session?.phase
                session?.handle(.toggle)
                return .pasted
            }
        }
        let reentrant = ReentrantDelivery()
        session = DictationSession(capture: capture, engine: engine, delivery: reentrant,
                                   feedback: feedback, history: history, clock: clock,
                                   settings: { [unowned self] in settings })
        reentrant.session = session
        dictate("hi")
        XCTAssertEqual(reentrant.phaseSeen, .delivering)
        XCTAssertEqual(capture.begins.count, 1)
        XCTAssertEqual(session.phase, .idle)
    }

    func testHoldReleaseStopsToggleStartedRecording() {
        dictate("mixed", via: .toggle, stop: .holdUp)
        XCTAssertEqual(delivery.delivered, ["mixed"])
    }

    func testReleaseWhileIdleIsIgnored() {
        session.handle(.holdUp)
        XCTAssertTrue(feedback.events.isEmpty)
        XCTAssertTrue(capture.ends.isEmpty)
    }

    // MARK: - Max duration

    func testMaxDurationStopsAndTranscribesWithNotice() {
        settings.maxSeconds = 120
        session.handle(.holdDown)
        capture.started()
        clock.advance(by: 120)

        XCTAssertEqual(session.phase, .transcribing)
        XCTAssertEqual(capture.ends.count, 1)
        XCTAssertEqual(feedback.events.suffix(2),
                       [.showProcessing,
                        .notify("Dictation stopped", "Dictation stopped at the 2-min limit — change it in Settings.")])
        XCTAssertTrue(clock.live.isEmpty)

        session.handle(.holdUp)   // the key, released after the auto-stop
        XCTAssertEqual(capture.ends.count, 1)
        capture.finishEnd()
        engine.finish(text: "long one")
        XCTAssertEqual(delivery.delivered, ["long one"])
    }

    func testNoLimitUsesCaptureCeiling() {
        settings.maxSeconds = 0
        session.handle(.holdDown)
        XCTAssertEqual(clock.live.first?.due, 1_000 + AudioCapture.ceilingSeconds)
        clock.advance(by: AudioCapture.ceilingSeconds)
        XCTAssertEqual(feedback.notifications, ["Dictation stopped"])
        XCTAssertTrue(feedback.events.contains(
            .notify("Dictation stopped", "Dictation stopped at the 30-min limit — change it in Settings.")))
    }

    func testMaxSecondsReadWhenRecordingStarts() {
        settings.maxSeconds = 120
        session.handle(.holdDown)
        settings.maxSeconds = 300
        XCTAssertEqual(clock.live.first?.due, 1_000 + 120)
    }

    func testStoppedRecordingsTimerCannotStopTheNextOne() {
        session.handle(.holdDown); clock.advance(by: 2); session.handle(.holdUp)
        capture.finishEnd(); engine.finish(text: "first")
        // The first recording's timer is cancelled, but a timer that fires
        // anyway (a cancel racing the run loop) must not touch the next one.
        let first = clock.timers[0]
        session.handle(.holdDown)
        first.action()

        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(capture.ends.count, 1)
        XCTAssertTrue(feedback.notifications.isEmpty)
        XCTAssertEqual(clock.live.count, 1)
    }

    // MARK: - Mic failing to start

    func testMicFailureWhileHeldEndsRecording() {
        session.handle(.holdDown)
        clock.advance(by: 0.1)
        capture.started(error: FakeError("no mic"))

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(engine.endPrewarms, 1)
        XCTAssertTrue(clock.live.isEmpty)
        XCTAssertEqual(feedback.events.suffix(2), [.notify("Couldn't start recording", "no mic"), .dismiss])

        session.handle(.holdUp)
        XCTAssertTrue(capture.ends.isEmpty)
        XCTAssertEqual(capture.cancels, 0)
        XCTAssertTrue(engine.jobs.isEmpty)
    }

    func testMicFailureAfterReleaseTranscribesNothing() {
        session.handle(.holdDown)
        clock.advance(by: 2)
        session.handle(.holdUp)           // released while the mic was still starting
        capture.started(error: FakeError("no mic"))
        capture.finishEnd([])             // the capture's empty end

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(engine.endPrewarms, 1)
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertEqual(feedback.notifications, ["Couldn't start recording"])
        XCTAssertEqual(feedback.cues, [.start], "No stop cue for a recording that never ran")
        XCTAssertEqual(feedback.events.last, .dismiss)
    }

    func testStaleMicFailureIgnoredByNewerRecording() {
        session.handle(.holdDown); clock.advance(by: 0.1); session.handle(.holdUp)   // tap, dropped
        session.handle(.holdDown)
        capture.started(1)
        capture.started(0, error: FakeError("old start failed"))

        XCTAssertEqual(session.phase, .recording)
        XCTAssertTrue(feedback.notifications.isEmpty)
        XCTAssertEqual(clock.live.count, 1)
        XCTAssertEqual(engine.endPrewarms, 1, "Only the tap's")
    }

    func testEmptyCaptureIsNotTranscribed() {
        session.handle(.holdDown); clock.advance(by: 2); session.handle(.holdUp)
        capture.finishEnd([])

        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertEqual(engine.endPrewarms, 1)
        XCTAssertEqual(feedback.events.last, .dismiss)
        XCTAssertEqual(session.phase, .idle)
    }

    // MARK: - Lost release

    func testReleaseBeforeMicStartsStillStops() {
        session.handle(.holdDown)
        clock.advance(by: 1)
        session.handle(.holdUp)           // begin still pending
        XCTAssertEqual(capture.ends.count, 1)
        XCTAssertTrue(clock.live.isEmpty)

        capture.started()                 // mic comes up after the release
        XCTAssertEqual(session.phase, .transcribing)
        capture.finishEnd()
        engine.finish(text: "quick")
        XCTAssertEqual(delivery.delivered, ["quick"])
    }

    // MARK: - Levels

    func testLevelsShownOnlyWhileRecording() {
        capture.onLevel?(0.1)
        session.handle(.holdDown)
        capture.onLevel?(0.5)
        clock.advance(by: 2)
        session.handle(.holdUp)
        capture.onLevel?(0.9)             // post-roll

        XCTAssertEqual(feedback.events.filter { if case .level = $0 { return true } else { return false } },
                       [.level(0.5)])
    }

    // MARK: - Text cleanup

    func testEmptyTextNeverReachesDelivery() {
        dictate("  \n ")
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(feedback.events.last, .dismiss)
        XCTAssertEqual(session.phase, .idle)
    }

    func testTagOnlyTextNeverReachesDelivery() {
        for raw in ["[BLANK_AUDIO]", " (music) ", "[Music] [Applause]", "[Music]\n(laughs)"] {
            dictate(raw)
        }
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testTrailingSpaceReadWhenRecordingStops() {
        session.handle(.holdDown)
        clock.advance(by: 2)
        session.handle(.holdUp)
        settings.trailingSpace = true   // changed mid-transcription: next dictation's
        capture.finishEnd()
        engine.finish(text: "one")

        dictate("two")
        XCTAssertEqual(delivery.delivered, ["one", "two "])
        XCTAssertEqual(history.entries.map(\.text), ["one", "two "])
    }

    func testCleanTrimsAndAddsTrailingSpace() {
        XCTAssertEqual(TranscriptCleanup.clean("  Hi there. \n", trailingSpace: false), "Hi there.")
        XCTAssertEqual(TranscriptCleanup.clean(" Hi there.", trailingSpace: true), "Hi there. ")
        XCTAssertEqual(TranscriptCleanup.clean("   ", trailingSpace: true), "")
    }

    func testCleanDropsTagOnlyText() {
        for raw in ["[BLANK_AUDIO]", "(music)", "[Music] [Applause]", " [Music]  (applause)\n[BLANK_AUDIO] ",
                    "()", "[ Silence ]"] {
            XCTAssertEqual(TranscriptCleanup.clean(raw, trailingSpace: true), "", raw)
        }
    }

    func testCleanKeepsSpeechThatHasTags() {
        XCTAssertEqual(TranscriptCleanup.clean("[Music] Hello", trailingSpace: false), "[Music] Hello")
        XCTAssertEqual(TranscriptCleanup.clean("[Music] hello [Music]", trailingSpace: false), "[Music] hello [Music]")
        XCTAssertEqual(TranscriptCleanup.clean("Call me (maybe)", trailingSpace: false), "Call me (maybe)")
        XCTAssertEqual(TranscriptCleanup.clean("[unclosed", trailingSpace: false), "[unclosed")
    }
}
