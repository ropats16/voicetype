import Foundation

// The seams between `DictationSession` and the rest of the app. The session
// owns every transition rule; each port is a thin adapter over a concrete
// piece (the mic capture, the transcription engine, text delivery, the
// indicator + sound cues + notifications, the history store, the clock
// — `Support/Clock.swift`). Tests drive the session with fakes of all of them.
//
// Every port is called on main, and must call its callbacks on main.

/// Records the audio for one dictation. `AudioCapture` already has this shape.
protocol DictationCapture: AnyObject {
    /// 0...1 level of the running recording, for the indicator. Set once by
    /// the session; called on main.
    var onLevel: ((Float) -> Void)? { get set }

    /// Starts a recording and returns at once. `started` is called once the
    /// source is running (`nil`) or failed to start (the error); after a
    /// failure the recording is over and `end` gets no samples.
    func begin(_ started: @escaping (Error?) -> Void)

    /// Ends the recording once its post-roll is in; `completion` gets the
    /// samples (empty if nothing was recorded).
    func end(_ completion: @escaping ([Float]) -> Void)

    /// Discards the recording.
    func cancel()
}

/// Turns recorded audio into text.
protocol DictationEngine: AnyObject {
    /// A job is coming: get the model ready and keep it loaded.
    func prewarm()
    /// The job `prewarm()` announced isn't coming.
    func endPrewarm()
    /// Transcribes 16 kHz mono samples; `completion` gets the raw text on main.
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void)
}

/// How delivered text reached the user.
enum DeliveryMethod: Equatable {
    /// Pasted into the focused field.
    case pasted
    /// No editable field was focused: left on the clipboard for the user.
    case copied
}

/// Text that reached the user, and how. Only a delivery that happened has
/// one, so a drop can't reach the history.
struct DeliveredText: Equatable {
    /// The cleaned text, as pasted or copied.
    let text: String
    let method: DeliveryMethod
}

/// What one delivery did.
enum DeliveryReport: Equatable {
    case delivered(DeliveredText)
    /// Nothing left after cleanup (silence, tag-only): nothing delivered.
    case droppedEmpty

    static func pasted(_ text: String) -> DeliveryReport { .delivered(DeliveredText(text: text, method: .pasted)) }
    static func copied(_ text: String) -> DeliveryReport { .delivered(DeliveredText(text: text, method: .copied)) }
}

/// Cleans a raw transcript and puts it where the user wants it (paste at the
/// caret, or the clipboard when nothing editable is focused), or drops it
/// when nothing is left; says which it did.
protocol DictationDelivery: AnyObject {
    func deliver(_ transcript: String, trailingSpace: Bool) -> DeliveryReport
}

/// What the user sees and hears: the indicator, sound cues, notifications.
protocol DictationFeedback: AnyObject {
    func showRecording()
    func showLevel(_ level: Float)
    func showProcessing()
    func dismiss()
    func play(_ cue: SoundCue)
    func notify(title: String, body: String)
}

/// Where delivered dictations are recorded. One `delivered` per dictation that
/// reached the user.
protocol DictationHistory: AnyObject {
    func delivered(_ delivered: DeliveredText)
}

/// Keeps no history.
final class NoDictationHistory: DictationHistory {
    func delivered(_ delivered: DeliveredText) {}
}

/// The dictation settings the session reads live: `maxSeconds` when a
/// recording starts, `trailingSpace` when it stops.
struct DictationSettings: Equatable {
    /// Recordings shorter than this are accidental taps and are dropped.
    var minSeconds: Double = 0.3
    /// Longest recording before it stops itself; `<= 0` = `ceilingSeconds`.
    var maxSeconds: Double
    /// The capture's own hard cap, used when `maxSeconds` sets no limit.
    var ceilingSeconds: Double
    /// Append a space after the delivered text.
    var trailingSpace: Bool

    /// The max-duration timer's length.
    var limitSeconds: Double { maxSeconds > 0 ? maxSeconds : ceilingSeconds }
}
