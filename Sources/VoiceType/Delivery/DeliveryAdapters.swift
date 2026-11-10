import AppKit
import CoreGraphics

// The live adapters behind delivery's ports. Thin on purpose: the clipboard
// rules live in `ClipboardPaster` and `ClipboardSnapshot`, the focus rules in
// `FocusRules`; these only move bytes and events.

/// An `NSPasteboard` — the general one in the app; tests pass a named one.
final class SystemClipboard: Clipboard {
    private let pasteboard: NSPasteboard
    /// Serves the latest paste write. The pasteboard doesn't keep its data
    /// provider alive, so we do: until our next write or restore replaces it,
    /// or the pasteboard says it's done (someone else took it).
    private var pasteText: PasteTextProvider?

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }

    /// Whether a paste write's provider is still held (tests).
    var isServingPasteText: Bool { pasteText != nil }

    func snapshot() -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ClipboardSnapshot.Item? in
            let representations = item.types.compactMap { type -> ClipboardSnapshot.Representation? in
                // Filter before reading: reading a file promise asks its source to fulfil it.
                guard ClipboardSnapshot.captures(type: type.rawValue), let data = item.data(forType: type)
                else { return nil }
                return ClipboardSnapshot.Representation(type: type.rawValue, data: data)
            }
            return representations.isEmpty ? nil : ClipboardSnapshot.Item(representations)
        }
        return ClipboardSnapshot(items: items)
    }

    func write(_ text: String) {
        pasteText = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func writeForPaste(_ text: String, onFirstRead: @escaping () -> Void) {
        let provider = PasteTextProvider(text, onFirstRead: onFirstRead) { [weak self] finished in
            if self?.pasteText === finished { self?.pasteText = nil }
        }
        // Set before clearing: the outgoing provider's "finished" mustn't drop this one.
        pasteText = provider
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: .init(ClipboardSnapshot.transientType))
        pasteboard.writeObjects([item])
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        pasteText = nil
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

/// Provides a paste write's text when someone first asks, and says so.
private final class PasteTextProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private var onFirstRead: (() -> Void)?
    private let onFinished: (PasteTextProvider) -> Void

    init(_ text: String, onFirstRead: @escaping () -> Void, onFinished: @escaping (PasteTextProvider) -> Void) {
        self.text = text
        self.onFirstRead = onFirstRead
        self.onFinished = onFinished
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        guard let read = onFirstRead else { return }
        onFirstRead = nil
        // Requests from other apps are serviced on main; be sure anyway.
        if Thread.isMainThread { read() } else { DispatchQueue.main.async(execute: read) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Thread.isMainThread { onFinished(self) } else { DispatchQueue.main.async { self.onFinished(self) } }
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
