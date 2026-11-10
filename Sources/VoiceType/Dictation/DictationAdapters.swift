import Foundation

// The live adapters behind `DictationSession`'s ports. Thin on purpose: every
// rule lives in the session.

extension AudioCapture: DictationCapture {}

/// The shared transcription engine; hands the raw text back on main.
final class EngineDictationAdapter: DictationEngine {
    private let engine: TranscriptionEngine

    init(_ engine: TranscriptionEngine) { self.engine = engine }

    func prewarm() { engine.prewarm() }
    func endPrewarm() { engine.endPrewarm() }

    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        engine.transcribe(samples) { result in
            DispatchQueue.main.async { completion(result.map(\.text)) }
        }
    }
}

/// The floating indicator, sound cues and notification banners.
final class IndicatorFeedback: DictationFeedback {
    private let indicator: IndicatorController
    private let soundCues: SoundCues

    init(indicator: IndicatorController = IndicatorController(), soundCues: SoundCues) {
        self.indicator = indicator
        self.soundCues = soundCues
    }

    func showRecording() { indicator.showRecording() }
    func showLevel(_ level: Float) { indicator.updateLevel(level) }
    func showProcessing() { indicator.showProcessing() }
    func dismiss() { indicator.dismiss() }
    func play(_ cue: SoundCue) { soundCues.play(cue) }
    func notify(title: String, body: String) { Notifier.notify(title: title, body: body) }
}
