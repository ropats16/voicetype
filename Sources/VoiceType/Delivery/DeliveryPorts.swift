import Foundation

// The seams between text delivery and the system. `ClipboardPaster` owns every
// clipboard rule (snapshot, burst, restore timing, the changeCount guard);
// each port is a thin adapter over a concrete piece (`NSPasteboard`, a
// synthesized ⌘V). Time comes from `DictationClock`. Tests drive the paster
// with fakes of all three.
//
// Every port is called on main.

/// The system clipboard.
protocol Clipboard: AnyObject {
    /// Bumps on every write by anyone. Lets the paster tell whether the
    /// clipboard still holds what it wrote.
    var changeCount: Int { get }
    /// Every item × every type's data, exactly as it is now.
    func snapshot() -> ClipboardSnapshot
    /// Replaces the contents with `text` as a plain string.
    func write(_ text: String)
    /// Replaces the contents with `snapshot` (an empty one clears it).
    func restore(_ snapshot: ClipboardSnapshot)
}

/// Sends the paste shortcut to the frontmost app.
protocol KeyPoster: AnyObject {
    /// Posts exactly ⌘V (key down + up).
    func postPaste()
}
