import Foundation

// The seams between text delivery and the system. `TextDelivery` owns cleanup
// and the paste-or-copy decision (via `FocusRules`); `ClipboardPaster` owns
// every clipboard rule (snapshot, burst, read-driven restore timing, the
// changeCount guard, ephemeral contents) with `ClipboardSnapshot` saying what
// a snapshot keeps. Each port is a thin adapter over a concrete piece (`NSPasteboard`, a
// synthesized ⌘V, the Accessibility API). Time comes from `Clock`.
// Tests drive both with fakes of all four.
//
// Every port is called on main.

/// The system clipboard.
protocol Clipboard: AnyObject {
    /// Bumps on every write by anyone (not on reads). Lets the paster tell
    /// whether the clipboard still holds what it wrote.
    var changeCount: Int { get }
    /// Every item × every type's data, exactly as it is now (minus what
    /// `ClipboardSnapshot` leaves out).
    func snapshot() -> ClipboardSnapshot
    /// Replaces the contents with `text` as a plain string, for the user to keep.
    func write(_ text: String)
    /// Replaces the contents with `text` as a plain string served on demand,
    /// marked transient. `onFirstRead` is called on main the first time anyone
    /// reads the text — the ⌘V target or, possibly first, a clipboard manager.
    func writeForPaste(_ text: String, onFirstRead: @escaping () -> Void)
    /// Replaces the contents with `snapshot` (an empty one clears it).
    func restore(_ snapshot: ClipboardSnapshot)
}

/// Sends the paste shortcut to the frontmost app.
protocol KeyPoster: AnyObject {
    /// Posts exactly ⌘V (key down + up).
    func postPaste()
}

/// What the Accessibility API says about the frontmost app's focus — raw
/// facts, before any rule (`FocusRules`) is applied.
struct FocusObservation: Equatable {
    enum Focused: Equatable {
        /// The focused element: its AX role and whether its value is settable.
        case element(role: String?, valueSettable: Bool)
        /// No focused element exposed (or any AX error other than a timeout).
        case none
        /// The frontmost app didn't answer within the AX messaging timeout.
        case timedOut
    }

    var focused: Focused
    /// The frontmost app's bundle id, if any.
    var bundleID: String?
    /// The frontmost app runs on Chromium (Electron apps, Chrome-family
    /// browsers), which reads the pasteboard late after ⌘V.
    var isChromiumHosted: Bool
}

/// Looks at the system's focused UI element. Must return promptly even when
/// the frontmost app is hung.
protocol FocusProbe: AnyObject {
    func observe() -> FocusObservation
}
