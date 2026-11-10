import Foundation

/// Pastes text through the clipboard and gives the user's clipboard back.
///
/// `paste` snapshots the clipboard, writes the text as a lazily served item,
/// posts ⌘V and schedules a restore of the snapshot. The restore waits for the
/// text to be *read* rather than a fixed delay (see `Timing`): an app that
/// reads late never pastes the old clipboard back, unless it reads after the
/// unread cap.
///
/// A burst of pastes (several dictations in quick succession) collapses to one
/// restore, of the clipboard as it was before the burst's first paste, timed
/// from the burst's last paste. Each paste is a new write, so it needs its own
/// read.
///
/// The restore is skipped when:
/// - the clipboard changed since our last write: the user or an app copied
///   something new, and that must never be clobbered. For the same reason a
///   paste mid-burst re-snapshots when the clipboard was changed under it —
///   the user's newer copy is what they expect back.
/// - the snapshot is ephemeral (`ClipboardSnapshot.isEphemeral`: a password
///   manager's concealed copy, another tool's transient write). Password
///   managers auto-clear their copy only while `changeCount` is still theirs;
///   our write already bumped it, so restoring would leave the secret on the
///   clipboard for good. The dictated text stays instead (rewritten plainly).
///
/// `copyOnly` leaves the text on the clipboard for the user and cancels any
/// pending restore, which would otherwise overwrite it.
///
/// Main-thread only.
final class ClipboardPaster {
    /// When the restore fires, measured from ⌘V.
    ///
    /// Restore at `max(⌘V + base, firstRead + readGrace)`; if nothing ever
    /// reads the text, at `⌘V + cap`.
    ///
    /// - `base` stays because the first reader isn't necessarily the target:
    ///   clipboard managers (Maccy, Raycast, Paste…) poll `changeCount` and
    ///   read new contents within ~0.5 s. Our paste write is marked transient,
    ///   which well-behaved ones honour by skipping it, but one that reads
    ///   anyway mustn't trigger a restore before the target has had its fixed
    ///   window — the pre-#10 behaviour, which is now the floor.
    /// - `readGrace` covers the rest of the reader's paste: the data reaching
    ///   it, and a second look at the pasteboard in the same handler.
    /// - `cap` bounds how long the user's clipboard is away when ⌘V landed
    ///   nowhere (nothing reads). The changeCount guard makes waiting safe; the
    ///   cost is only that a manual ⌘V meanwhile pastes the dictation.
    enum Timing {
        struct Pace: Equatable {
            /// Never restore sooner than this after ⌘V.
            let base: TimeInterval
            /// Restore this long after an unread ⌘V.
            let cap: TimeInterval
        }

        /// Native apps read the pasteboard while handling the ⌘V key event,
        /// well inside 0.2 s (the long-standing fixed delay). 3 s of unread
        /// means ⌘V landed nowhere or the app is stuck.
        static let native = Pace(base: 0.2, cap: 3)
        /// Electron/Chromium apps (VS Code, Slack, Claude…) and apps that timed
        /// out the focus probe handle ⌘V asynchronously; under load the read
        /// overruns 0.2 s. 1 s base covers a busy renderer when a clipboard
        /// manager read first; 5 s cap gives a hung app time to come back.
        static let slowApp = Pace(base: 1.0, cap: 5)
        static let readGrace: TimeInterval = 0.15
    }

    private let clipboard: Clipboard
    private let keyPoster: KeyPoster
    private let clock: Clock

    /// The restore owed to the user while a burst is in flight.
    private struct Pending {
        /// The clipboard before the burst's first paste.
        let origin: ClipboardSnapshot
        /// The latest paste's text.
        let text: String
        /// Which of our writes is on the clipboard (`writes` at the time).
        let write: Int
        /// `changeCount` right after that write.
        let written: Int
        /// No restore before this: the latest-ending `⌘V + base` of the burst,
        /// so a faster app never cuts short an earlier, slower one.
        let floor: TimeInterval
        /// The restore if the latest write is never read.
        let unreadDue: TimeInterval
        var firstReadAt: TimeInterval?
        var timer: ClockTimer?

        var due: TimeInterval {
            max(floor, firstReadAt.map { $0 + Timing.readGrace } ?? unreadDue)
        }
    }
    private var pending: Pending?
    private var writes = 0

    init(clipboard: Clipboard, keyPoster: KeyPoster, clock: Clock) {
        self.clipboard = clipboard
        self.keyPoster = keyPoster
        self.clock = clock
    }

    /// Whether a clipboard restore is scheduled.
    var isRestorePending: Bool { pending != nil }

    /// Pastes `text` at the caret of the frontmost app. `slowApp` (an
    /// Electron/Chromium or unresponsive app) gets `Timing.slowApp` instead of
    /// `Timing.native`. Empty text does nothing.
    func paste(_ text: String, slowApp: Bool = false) {
        guard !text.isEmpty else { return }
        let pace = slowApp ? Timing.slowApp : Timing.native
        let now = clock.now

        let origin: ClipboardSnapshot
        var floor = now + pace.base
        if let prior = pending {
            prior.timer?.cancel()
            floor = max(floor, prior.floor)
            origin = clipboard.changeCount == prior.written ? prior.origin : clipboard.snapshot()
        } else {
            origin = clipboard.snapshot()
        }

        writes += 1
        let write = writes
        clipboard.writeForPaste(text) { [weak self] in self?.firstRead(of: write) }
        // Before ⌘V: the read it triggers needs a pending restore to arm.
        pending = Pending(origin: origin, text: text, write: write, written: clipboard.changeCount,
                          floor: floor, unreadDue: now + pace.cap)
        keyPoster.postPaste()
        arm()
    }

    /// Leaves `text` on the clipboard without pasting, and drops any pending
    /// restore: the user now wants this text on the clipboard.
    func copyOnly(_ text: String) {
        cancelPending()
        clipboard.write(text)
    }

    private func firstRead(of write: Int) {
        guard var owed = pending, owed.write == write, owed.firstReadAt == nil else { return }
        owed.firstReadAt = clock.now
        pending = owed
        arm()
    }

    /// (Re)schedules the pending restore at its current due time.
    private func arm() {
        guard var owed = pending else { return }
        owed.timer?.cancel()
        owed.timer = clock.schedule(after: max(0, owed.due - clock.now)) { [weak self] in self?.restoreNow() }
        pending = owed
    }

    private func cancelPending() {
        pending?.timer?.cancel()
        pending = nil
    }

    private func restoreNow() {
        guard let owed = pending else { return }
        pending = nil
        guard clipboard.changeCount == owed.written else { return }
        if owed.origin.isEphemeral {
            // Leave the dictation, written plainly: a lazy item left for good
            // would lose its text if we quit or crashed before anyone read it.
            clipboard.write(owed.text)
        } else {
            clipboard.restore(owed.origin)
        }
    }
}
