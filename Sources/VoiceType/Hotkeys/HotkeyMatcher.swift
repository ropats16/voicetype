import CoreGraphics

/// Pure, unit-testable hotkey logic split out of `HotkeyManager` so the
/// binding-satisfaction rules and press/release edge detection can be exercised
/// with synthetic event tuples — no real `CGEventTap` required. Nothing here
/// touches AppKit or any live tap state.
enum HotkeyMatcher {

    /// Whether `binding` is **satisfied** by the event described by
    /// `(eventType, keyCode, flags, isAutorepeat)`, or `nil` when the event is
    /// irrelevant to the binding (so the caller leaves the binding's state
    /// untouched). The three cases mirror `KeyBinding`'s forms:
    ///
    /// - **Pure-modifier combo** (`keyCode < 0`, modifiers non-empty): only
    ///   `.flagsChanged` is relevant; satisfied iff the required modifier flags
    ///   are non-empty and `flags` is a superset of them.
    /// - **Single modifier** (`modifiers` empty, modifier key code): only a
    ///   `.flagsChanged` for that key code is relevant; satisfied iff the key's
    ///   device bit is set in `flags`.
    /// - **Regular key + optional modifiers**: a `.keyDown` for the key code is
    ///   satisfied iff `flags` is a superset of the required modifiers — this is
    ///   the fix for the old keyCode-only path that ignored modifiers (needed
    ///   for ⌃⌥Space). A `.keyUp` for it is not satisfied; an autorepeat
    ///   `.keyDown` is irrelevant, so a still-held key can't read as a new press.
    static func satisfaction(
        of binding: KeyBinding,
        eventType: CGEventType,
        keyCode: Int,
        flags: CGEventFlags,
        isAutorepeat: Bool
    ) -> Bool? {
        // Pure-modifier combo (e.g. ⌃⇧): evaluated on every flagsChanged.
        if binding.keyCode < 0, !binding.modifiers.isEmpty {
            guard eventType == .flagsChanged else { return nil }
            let required = HotkeyManager.flags(for: binding.modifiers)
            return !required.isEmpty && flags.isSuperset(of: required)
        }

        // Single modifier (Right ⌥, Left ⌃, …): press/release via the device bit.
        if binding.modifiers.isEmpty, HotkeyManager.isModifierKeyCode(binding.keyCode) {
            guard eventType == .flagsChanged, keyCode == binding.keyCode else { return nil }
            return (flags.rawValue & HotkeyManager.deviceBit(for: binding.keyCode)) != 0
        }

        // Regular key + optional modifiers (e.g. ⌃⌥Space).
        guard keyCode == binding.keyCode else { return nil }
        switch eventType {
        case .keyDown:
            if isAutorepeat { return nil }   // a still-held key, not a new press
            return flags.isSuperset(of: HotkeyManager.flags(for: binding.modifiers))
        case .keyUp:
            return false
        default:
            return nil
        }
    }

    /// Whether the event is a fresh key-down for `cancelKeyCode` (default Esc).
    /// The cancel key is a plain key with no required modifiers, so — unlike the
    /// rebindable hold/toggle bindings — it needs only a "regular key down, this
    /// key code" test rather than the full satisfaction logic. Autorepeat
    /// key-downs are ignored so a held key can't fire repeated cancels; key-ups
    /// and other key codes are irrelevant.
    static func isCancelKeyDown(
        eventType: CGEventType,
        keyCode: Int,
        cancelKeyCode: Int,
        isAutorepeat: Bool
    ) -> Bool {
        eventType == .keyDown && keyCode == cancelKeyCode && !isAutorepeat
    }
}

/// Stateful press/release edge detector over a stream of satisfaction readings.
/// A `nil` reading leaves state untouched; a `false → true` transition is a
/// **press** edge and `true → false` a **release** edge. A held / auto-repeating
/// key therefore yields a press exactly once per physical press.
struct EdgeDetector {
    enum Edge: Equatable { case press, release }

    private(set) var active = false

    /// Folds the latest satisfaction reading into the detector, returning the
    /// edge crossed (if any).
    mutating func update(with satisfied: Bool?) -> Edge? {
        guard let satisfied, satisfied != active else { return nil }
        active = satisfied
        return satisfied ? .press : .release
    }
}
