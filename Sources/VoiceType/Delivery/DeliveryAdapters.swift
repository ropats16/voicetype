import AppKit
import CoreGraphics

// The live adapters behind delivery's ports. Thin on purpose: every rule
// lives in `ClipboardPaster`.

/// An `NSPasteboard` — the general one in the app; tests pass a named one.
final class SystemClipboard: Clipboard {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ClipboardSnapshot.Item? in
            let representations = item.types.compactMap { type in
                item.data(forType: type).map { ClipboardSnapshot.Representation(type: type.rawValue, data: $0) }
            }
            return representations.isEmpty ? nil : ClipboardSnapshot.Item(representations)
        }
        return ClipboardSnapshot(items: items)
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.items.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in snapshotItem.representations {
                item.setData(representation.data, forType: .init(representation.type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

/// Posts ⌘V as synthesized key events at the HID tap.
final class CGEventKeyPoster: KeyPoster {
    /// Virtual key code for "v".
    private static let vKeyCode: CGKeyCode = 0x09

    func postPaste() {
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
}
