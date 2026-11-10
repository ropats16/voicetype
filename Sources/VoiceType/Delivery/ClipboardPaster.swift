import Foundation

/// Pastes text through the clipboard and gives the user's clipboard back.
///
/// `paste` snapshots the clipboard, writes the text, posts ⌘V and schedules a
/// restore of the snapshot. A burst of pastes (several dictations in quick
/// succession) collapses to one restore, of the clipboard as it was before
/// the burst's first paste, a full delay after the burst's last paste.
///
/// The restore is skipped when the clipboard changed since our last write:
/// the user or an app copied something new, and that must never be clobbered.
/// For the same reason a paste mid-burst re-snapshots when the clipboard was
/// changed under it — the user's newer copy is what they expect back.
///
/// `copyOnly` leaves the text on the clipboard for the user and cancels any
/// pending restore, which would otherwise overwrite it.
///
/// Main-thread only.
final class ClipboardPaster {
    /// How long after ⌘V the target app may still be reading the clipboard.
    enum Timing {
        /// Native apps read the pasteboard while handling the ⌘V key event,
        /// well inside this. 0.2 s is the value the old `TextInserter` shipped with.
        static let restoreDelay: TimeInterval = 0.2
        /// Electron/Chromium apps (VS Code, Slack, Claude…) handle ⌘V on their
        /// renderer process and read the pasteboard asynchronously; under load
        /// that overruns 0.2 s and they paste the restored *old* clipboard.
        /// 1 s covers a busy renderer; the changeCount guard makes the longer
        /// wait safe (anything copied meanwhile is never overwritten).
        static let slowAppRestoreDelay: TimeInterval = 1.0
    }

    private let pasteboard: Clipboard
    private let keyPoster: KeyPoster
    private let clock: DictationClock

    /// The restore owed to the user while a burst is in flight.
    private struct Pending {
        /// The clipboard before the burst's first paste.
        let origin: ClipboardSnapshot
        /// `changeCount` right after our latest write.
        let written: Int
        /// When the restore fires (`clock.now` seconds).
        let due: TimeInterval
        let timer: DictationTimer
    }
    private var pending: Pending?

    init(pasteboard: Clipboard, keyPoster: KeyPoster, clock: DictationClock) {
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.clock = clock
    }

    /// Whether a clipboard restore is scheduled.
    var isRestorePending: Bool { pending != nil }

    /// Pastes `text` at the caret of the frontmost app. `slowApp` (an
    /// Electron/Chromium app) waits `Timing.slowAppRestoreDelay` before
    /// restoring instead of `Timing.restoreDelay`. Empty text does nothing.
    func paste(_ text: String, slowApp: Bool = false) {
        guard !text.isEmpty else { return }

        let origin: ClipboardSnapshot
        var due = clock.now + (slowApp ? Timing.slowAppRestoreDelay : Timing.restoreDelay)
        if let prior = pending {
            prior.timer.cancel()
            // An earlier app in the burst may be slower: never restore before it's done.
            due = max(due, prior.due)
            origin = pasteboard.changeCount == prior.written ? prior.origin : pasteboard.snapshot()
        } else {
            origin = pasteboard.snapshot()
        }

        pasteboard.write(text)
        let written = pasteboard.changeCount
        keyPoster.postPaste()

        let timer = clock.schedule(after: due - clock.now) { [weak self] in self?.restoreNow() }
        pending = Pending(origin: origin, written: written, due: due, timer: timer)
    }

    /// Leaves `text` on the clipboard without pasting, and drops any pending
    /// restore: the user now wants this text on the clipboard.
    func copyOnly(_ text: String) {
        cancelPending()
        pasteboard.write(text)
    }

    private func cancelPending() {
        pending?.timer.cancel()
        pending = nil
    }

    private func restoreNow() {
        guard let owed = pending else { return }
        pending = nil
        guard pasteboard.changeCount == owed.written else { return }
        pasteboard.restore(owed.origin)
    }
}
