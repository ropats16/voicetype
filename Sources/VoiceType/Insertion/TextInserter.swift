import Foundation
import AppKit
import CoreGraphics

/// Inserts text into the focused field by writing it to the pasteboard,
/// synthesizing ⌘V, then restoring the previous clipboard contents. This works
/// universally — browsers, native apps, Terminal, and the Claude Code CLI —
/// because it relies on the standard paste path rather than per-app hooks.
final class TextInserter {
    /// Captured clipboard contents, restored after the paste lands.
    private struct Snapshot {
        let items: [[String: Data]]
    }

    /// virtual key code for "v".
    private static let vKeyCode: CGKeyCode = 0x09

    /// How long to wait before restoring the clipboard, giving the target app
    /// time to read the pasted contents.
    private let restoreDelay: TimeInterval = 0.2

    /// Coordinates restores across overlapping `insert()` calls (rapid
    /// successive dictations) so a burst collapses to exactly one correct
    /// restore instead of each call's stale snapshot clobbering the others.
    /// See `RestoreScheduler`.
    private var restoreScheduler = RestoreScheduler()

    /// The clipboard as it was before the first insert of the current burst.
    /// Only valid while a restore is pending; set on the burst's first
    /// `insert(_:)` and consumed by whichever restore ultimately fires.
    private var originSnapshot = Snapshot(items: [])

    /// Writes `text` to the clipboard, pastes it, and restores the prior
    /// clipboard. Must be called on the main thread.
    func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let (shouldCaptureOrigin, token) = restoreScheduler.beginInsert()
        if shouldCaptureOrigin {
            originSnapshot = capture()
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        synthesizePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            self?.restoreIfCurrent(token)
        }
    }

    /// Leaves `text` on the clipboard without pasting (no-field fallback,
    /// expanded in Phase 3).
    func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Paste synthesis

    private func synthesizePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        // Force exactly ⌘V — overrides any modifier (e.g. a held Option hotkey)
        // the system may still consider down.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard snapshot / restore

    private func capture() -> Snapshot {
        let pb = NSPasteboard.general
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            if !dict.isEmpty { items.append(dict) }
        }
        return Snapshot(items: items)
    }

    /// Restores `originSnapshot` iff `token` is still the most recently
    /// issued one (i.e. this is the last insert of its burst) — a superseded
    /// token is a no-op, per `RestoreScheduler`.
    private func restoreIfCurrent(_ token: RestoreScheduler.Token) {
        guard restoreScheduler.restoreFired(token) else { return }
        restore(originSnapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for dict in snapshot.items {
            let item = NSPasteboardItem()
            for (raw, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            restored.append(item)
        }
        pb.writeObjects(restored)
    }
}
