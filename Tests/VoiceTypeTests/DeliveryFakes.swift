@testable import VoiceType
import Foundation

// Fakes for the delivery ports, shared by `ClipboardPasterTests` and
// `TextDeliveryTests`.

final class ManualClock: DictationClock {
    final class Pending: DictationTimer {
        let due: TimeInterval
        let action: () -> Void
        var isCancelled = false
        var hasFired = false
        init(due: TimeInterval, action: @escaping () -> Void) { self.due = due; self.action = action }
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 1_000
    private(set) var timers: [Pending] = []

    /// Timers neither fired nor cancelled.
    var live: [Pending] { timers.filter { !$0.isCancelled && !$0.hasFired } }

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> DictationTimer {
        let timer = Pending(due: now + seconds, action: action)
        timers.append(timer)
        return timer
    }

    /// Moves time on, firing every live timer that comes due.
    func advance(by seconds: TimeInterval) {
        now += seconds
        for timer in timers where !timer.isCancelled && !timer.hasFired && timer.due <= now {
            timer.hasFired = true
            timer.action()
        }
    }
}

/// An in-memory pasteboard. Every write bumps `changeCount`, like the real one.
final class FakePasteboard: Clipboard {
    private(set) var contents: ClipboardSnapshot
    private(set) var changeCount = 0
    private(set) var restores: [ClipboardSnapshot] = []
    private(set) var snapshotsTaken = 0

    init(_ contents: ClipboardSnapshot = .empty) { self.contents = contents }

    func snapshot() -> ClipboardSnapshot {
        snapshotsTaken += 1
        return contents
    }

    func write(_ text: String) {
        contents = ClipboardSnapshot(items: [.init([.init(type: Self.plainText, data: Data(text.utf8))])])
        changeCount += 1
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        restores.append(snapshot)
        contents = snapshot
        changeCount += 1
    }

    /// Something other than the paster (the user, another app) copies.
    func externalCopy(_ text: String) {
        contents = ClipboardSnapshot(items: [.init([.init(type: Self.plainText, data: Data(text.utf8))])])
        changeCount += 1
    }

    var text: String? {
        contents.items.first?.representations.first { $0.type == Self.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    static let plainText = "public.utf8-plain-text"
}

final class FakeKeyPoster: KeyPoster {
    private(set) var pastes = 0
    /// What the pasteboard held each time ⌘V was posted.
    var onPaste: (() -> Void)?
    func postPaste() { pastes += 1; onPaste?() }
}

/// Reports a scripted focus observation; counts how often it was asked.
final class FakeFocusProbe: FocusProbe {
    var observation: FocusObservation
    private(set) var observations = 0

    init(_ observation: FocusObservation = .nativeTextField) { self.observation = observation }

    func observe() -> FocusObservation {
        observations += 1
        return observation
    }
}

extension FocusObservation {
    /// A text field in a native (non-Chromium) app.
    static let nativeTextField = FocusObservation(focused: .element(role: "AXTextField", valueSettable: true),
                                                  bundleID: "com.apple.TextEdit", isChromiumHosted: false)
}
