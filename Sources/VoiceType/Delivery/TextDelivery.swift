import Foundation

/// Delivers one transcript to the user and says how: the single entry point
/// for text delivery.
///
/// 1. Cleanup: non-speech tags are stripped anywhere (`NonSpeechFilter`, the
///    app's one tag rule), whitespace trimmed, and a trailing space added if
///    asked. Nothing left → `.droppedEmpty`, with no AX or clipboard work.
/// 2. Focus: the probe's observation goes through `FocusRules` — editable or
///    unknown → paste, not editable → copy.
/// 3. Paste or copy through `ClipboardPaster`, which snapshots and restores
///    the user's clipboard after the burst's last paste, late for
///    Chromium/Electron (or timed-out) apps; a copy cancels any pending restore.
///
/// Main-thread only.
final class TextDelivery: DictationDelivery {
    private let paster: ClipboardPaster
    private let probe: FocusProbe

    init(paster: ClipboardPaster, probe: FocusProbe) {
        self.paster = paster
        self.probe = probe
    }

    /// The live delivery: the general pasteboard, a synthesized ⌘V, the
    /// Accessibility API and the system clock.
    convenience init() {
        self.init(paster: ClipboardPaster(pasteboard: SystemClipboard(),
                                          keyPoster: CGEventKeyPoster(),
                                          clock: SystemDictationClock()),
                  probe: AXFocusProbe())
    }

    @discardableResult
    func deliver(_ transcript: String, trailingSpace: Bool) -> DeliveryReport {
        let text = Self.clean(transcript, trailingSpace: trailingSpace)
        guard !text.isEmpty else { return DeliveryReport(outcome: .droppedEmpty, text: "") }

        let focus = FocusRules.report(for: probe.observe())
        switch focus.verdict {
        case .editable, .unknown:
            paster.paste(text, slowApp: focus.isSlowApp)
            return DeliveryReport(outcome: .pasted, text: text)
        case .notEditable:
            paster.copyOnly(text)
            return DeliveryReport(outcome: .copied, text: text)
        }
    }

    /// `raw` without non-speech tags (`NonSpeechFilter`: tag-only text becomes
    /// "", inline tags are removed), trimmed; non-empty text gets a trailing
    /// space if asked. "" when there is nothing to deliver. The whisper adapter
    /// already filters each segment; this repeats it on the whole transcript so
    /// every engine gets the same rule.
    static func clean(_ raw: String, trailingSpace: Bool) -> String {
        var text = NonSpeechFilter.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && trailingSpace { text += " " }
        return text
    }
}
