@testable import VoiceType
import Foundation

// Fakes for the delivery ports, shared by `ClipboardPasterTests` and
// `TextDeliveryTests`.

/// An in-memory pasteboard. Every write bumps `changeCount`, like the real one.
/// A paste write is served lazily: its first reader (`read()`, or our own
/// `snapshot()`) fires the write's `onFirstRead`, once.
final class FakePasteboard: Clipboard {
    private(set) var contents: ClipboardSnapshot
    private(set) var changeCount = 0
    private(set) var restores: [ClipboardSnapshot] = []
    private(set) var snapshotsTaken = 0
    /// Every plain (non-paste) write's text.
    private(set) var plainWrites: [String] = []
    /// Every paste write's `onFirstRead`, in order — lets a test fire a stale one.
    private(set) var readHooks: [() -> Void] = []
    /// The current paste write's hook, until it's read or the contents change.
    private var unread: (() -> Void)?

    init(_ contents: ClipboardSnapshot = .empty) { self.contents = contents }

    func snapshot() -> ClipboardSnapshot {
        snapshotsTaken += 1
        fireFirstRead()
        return contents
    }

    func write(_ text: String) {
        plainWrites.append(text)
        replace(with: Self.plain(text))
    }

    func writeForPaste(_ text: String, onFirstRead: @escaping () -> Void) {
        replace(with: Self.plain(text))
        readHooks.append(onFirstRead)
        unread = onFirstRead
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        restores.append(snapshot)
        replace(with: snapshot)
    }

    /// Something other than the paster (the user, another app) copies.
    func externalCopy(_ text: String) { replace(with: Self.plain(text)) }

    /// An app (the ⌘V target, a clipboard manager) reads the text. Reads
    /// don't bump `changeCount`.
    @discardableResult
    func read() -> String? {
        fireFirstRead()
        return text
    }

    var text: String? {
        contents.items.first?.representations.first { $0.type == Self.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    static let plainText = "public.utf8-plain-text"

    private func replace(with snapshot: ClipboardSnapshot) {
        contents = snapshot
        changeCount += 1
        unread = nil
    }

    private func fireFirstRead() {
        let hook = unread
        unread = nil
        hook?()
    }

    private static func plain(_ text: String) -> ClipboardSnapshot {
        ClipboardSnapshot(items: [.init([.init(type: plainText, data: Data(text.utf8))])])
    }
}

final class FakeKeyPoster: KeyPoster {
    private(set) var pastes = 0
    /// Runs on each ⌘V — e.g. the target app reading the pasteboard.
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
