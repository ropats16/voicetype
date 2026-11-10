import Foundation

/// Inserts text into the focused field by writing it to the pasteboard,
/// synthesizing ⌘V, then restoring the previous clipboard contents. This works
/// universally — browsers, native apps, Terminal, and the Claude Code CLI —
/// because it relies on the standard paste path rather than per-app hooks.
///
/// Now a thin shim over `ClipboardPaster` (Delivery/), kept until the text
/// delivery facade replaces it.
final class TextInserter {
    private let paster = ClipboardPaster(pasteboard: SystemClipboard(),
                                         keyPoster: CGEventKeyPoster(),
                                         clock: SystemDictationClock())

    /// Writes `text` to the clipboard, pastes it, and restores the prior
    /// clipboard. Must be called on the main thread.
    func insert(_ text: String) {
        paster.paste(text)
    }

    /// Leaves `text` on the clipboard without pasting. Must be called on the
    /// main thread.
    func copyOnly(_ text: String) {
        paster.copyOnly(text)
    }
}
