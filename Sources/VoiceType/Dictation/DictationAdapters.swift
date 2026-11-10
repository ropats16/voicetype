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

/// Pastes at the caret, or leaves the text on the clipboard when the focused
/// element isn't editable. `.unknown` (no focused element exposed, e.g. an
/// Electron app whose AX tree isn't up yet) pastes anyway: best-effort ⌘V is
/// what users expect and works in every app we've seen.
final class PasteDelivery: DictationDelivery {
    private let focusVerdict: () -> CaretLocator.FocusVerdict
    private let paste: (String) -> Void
    private let copy: (String) -> Void

    init(focusVerdict: @escaping () -> CaretLocator.FocusVerdict,
         paste: @escaping (String) -> Void,
         copy: @escaping (String) -> Void) {
        self.focusVerdict = focusVerdict
        self.paste = paste
        self.copy = copy
    }

    convenience init(caretLocator: CaretLocator = CaretLocator(), inserter: TextInserter = TextInserter()) {
        self.init(focusVerdict: { caretLocator.focusVerdict() },
                  paste: { inserter.insert($0) },
                  copy: { inserter.copyOnly($0) })
    }

    func deliver(_ text: String) -> DeliveryOutcome {
        switch focusVerdict() {
        case .editable, .unknown:
            paste(text)
            return .pasted
        case .notEditable:
            copy(text)
            return .copied
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
