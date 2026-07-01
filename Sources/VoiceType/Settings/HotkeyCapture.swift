import AppKit   // for NSEvent.ModifierFlags only

/// Pure conversion helpers for live hotkey capture. No AppKit event monitoring
/// lives here — only the mapping from decoded inputs to `KeyBinding` — so the
/// entire type is unit-testable without UI, hardware, or a real event tap.
enum HotkeyCapture {

    /// Canonical modifier names present in `flags`, in a stable order:
    /// control, option, shift, command, function. The `.control` / `.option` etc.
    /// members of `NSEvent.ModifierFlags` are already device-independent (they
    /// match both left and right variants), so no additional masking is needed.
    static func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.control)  { names.append("control") }
        if flags.contains(.option)   { names.append("option") }
        if flags.contains(.shift)    { names.append("shift") }
        if flags.contains(.command)  { names.append("command") }
        if flags.contains(.function) { names.append("function") }
        return names
    }

    /// Form 3 — a regular (non-modifier) key with (optional) held modifiers.
    static func regularKeyBinding(keyCode: Int, flags: NSEvent.ModifierFlags) -> KeyBinding {
        KeyBinding(keyCode: keyCode, modifiers: modifierNames(from: flags))
    }

    /// Modifier-only capture → form 1 or form 2:
    /// - `names.count >= 2`  → pure-modifier combo (keyCode -1, modifiers = names).
    /// - `names.count == 1` AND `lastModifierKeyCode` is a valid modifier key code
    ///                        → single modifier (keyCode = lastModifierKeyCode, modifiers []).
    /// - otherwise           → nil (nothing to commit).
    static func modifierOnlyBinding(names: [String], lastModifierKeyCode: Int?) -> KeyBinding? {
        if names.count >= 2 {
            return KeyBinding(keyCode: -1, modifiers: names)
        }
        if names.count == 1,
           let kc = lastModifierKeyCode,
           HotkeyManager.isModifierKeyCode(kc) {
            return KeyBinding(keyCode: kc, modifiers: [])
        }
        return nil
    }
}
