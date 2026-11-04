import CoreGraphics

/// A global key binding, and the single home of the hotkey vocabulary: modifier
/// names and aliases, the modifier key-code table, description, satisfaction,
/// validation and capture. Everything here is pure, so it is tested through this
/// interface with synthetic `KeyEvent`s; the event tap and the Settings recorder
/// are thin adapters that decode real events into `KeyEvent`s.
///
/// Three forms:
/// - **Modifier combo** (default hold = Control+Shift): `keyCode < 0`, `modifiers`
///   lists the pure modifiers that must be held together. Types nothing.
/// - **Single modifier** (e.g. Right Option): `modifiers` empty, `keyCode` is the
///   modifier's key code; left/right is distinguished via the device bit.
/// - **Regular key + modifiers** (e.g. ⌃⌥Space): `keyCode` is the key, with
///   `modifiers`.
///
/// `modifiers` stays as the raw config strings so hand-edited aliases ("cmd",
/// "Ctrl") round-trip untouched; they are resolved through `Modifier(name:)`
/// wherever they are interpreted.
struct KeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: [String]

    /// Control + Shift — default hold-to-talk. A pure-modifier combo, so it
    /// never inserts a character into the focused field, and (unlike fn/Globe)
    /// both modifiers are reliably delivered to the event tap.
    static let controlShift = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
    /// fn + Shift — alternative combo; note the Globe/fn key is intercepted by
    /// the system on some Macs and may not reach the event tap.
    static let fnShift = KeyBinding(keyCode: -1, modifiers: ["function", "shift"])
    /// Right Option (⌥) — alternative single-modifier hold.
    static let rightOption = KeyBinding(keyCode: 61, modifiers: [])
    /// ⌃⌥Space — default toggle key.
    static let controlOptionSpace = KeyBinding(keyCode: 49, modifiers: ["control", "option"])

    static let spaceKeyCode = 49
    /// Default cancel key; also aborts a Settings capture.
    static let escapeKeyCode = 53

    // MARK: - Modifier vocabulary

    /// A binding modifier. Case order is the canonical display/capture order.
    enum Modifier: String, CaseIterable {
        case control, option, shift, command, function

        /// Resolves a config name, case-insensitively, including aliases.
        init?(name: String) {
            switch name.lowercased() {
            case "control", "ctrl": self = .control
            case "option", "alt": self = .option
            case "shift": self = .shift
            case "command", "cmd": self = .command
            case "function", "fn", "globe": self = .function
            default: return nil
            }
        }

        /// Device-independent flag; `NSEvent.ModifierFlags` uses the same bits.
        var flag: CGEventFlags {
            switch self {
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .shift: return .maskShift
            case .command: return .maskCommand
            case .function: return .maskSecondaryFn
            }
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            case .function: return "fn"
            }
        }

        /// The modifiers held in `flags`, in canonical order.
        static func held(in flags: CGEventFlags) -> [Modifier] {
            allCases.filter { flags.contains($0.flag) }
        }
    }

    /// A physical, sided modifier key — the only keys usable as a single-modifier
    /// binding, because only they carry a device bit that tells press from
    /// release on `flagsChanged`. (fn has no sided bit, so it can only combine.)
    private struct ModifierKey {
        let keyCode: Int
        let modifier: Modifier
        let side: String
        /// NX_DEVICE…KEYMASK bit in the raw event flags.
        let deviceBit: UInt64
    }

    private static let modifierKeys: [ModifierKey] = [
        ModifierKey(keyCode: 59, modifier: .control, side: "Left", deviceBit: 0x01),
        ModifierKey(keyCode: 62, modifier: .control, side: "Right", deviceBit: 0x2000),
        ModifierKey(keyCode: 58, modifier: .option, side: "Left", deviceBit: 0x20),
        ModifierKey(keyCode: 61, modifier: .option, side: "Right", deviceBit: 0x40),
        ModifierKey(keyCode: 56, modifier: .shift, side: "Left", deviceBit: 0x02),
        ModifierKey(keyCode: 60, modifier: .shift, side: "Right", deviceBit: 0x04),
        ModifierKey(keyCode: 55, modifier: .command, side: "Left", deviceBit: 0x08),
        ModifierKey(keyCode: 54, modifier: .command, side: "Right", deviceBit: 0x10),
    ]

    private static func modifierKey(_ keyCode: Int) -> ModifierKey? {
        modifierKeys.first { $0.keyCode == keyCode }
    }

    /// Which of the three forms this binding takes; the only place that reads
    /// the `keyCode < 0` / empty-`modifiers` encoding.
    private enum Form {
        case unmatchable
        case combo
        case singleModifier(ModifierKey)
        case key
    }

    private var form: Form {
        if keyCode < 0 { return modifiers.isEmpty ? .unmatchable : .combo }
        if modifiers.isEmpty, let key = Self.modifierKey(keyCode) { return .singleModifier(key) }
        return .key
    }

    /// A pure-modifier combo binding.
    private static func combo(_ modifiers: [Modifier]) -> KeyBinding {
        KeyBinding(keyCode: -1, modifiers: modifiers.map(\.rawValue))
    }

    /// The recognised modifiers, deduplicated, in canonical order.
    private var resolvedModifiers: [Modifier] {
        let set = Set(modifiers.compactMap(Modifier.init(name:)))
        return Modifier.allCases.filter(set.contains)
    }

    private var requiredFlags: CGEventFlags {
        resolvedModifiers.reduce(into: []) { $0.insert($1.flag) }
    }

    // MARK: - Satisfaction

    /// Whether this binding is **satisfied** by `event`, or `nil` when the event
    /// is irrelevant to it (so edge state is left untouched):
    ///
    /// - **Pure-modifier combo**: only `.flagsChanged` is relevant; satisfied iff
    ///   the required flags are non-empty and all held.
    /// - **Single modifier**: only a `.flagsChanged` for that key code is
    ///   relevant; satisfied iff the key's device bit is set.
    /// - **Regular key**: a fresh `.keyDown` for the key code is satisfied iff
    ///   every required modifier is held, so ⌃Space can't fire a ⌃⌥Space
    ///   binding; its `.keyUp` is not satisfied; an autorepeat `.keyDown` is
    ///   irrelevant, so a still-held key can't read as a new press.
    func satisfaction(by event: KeyEvent) -> Bool? {
        switch form {
        case .unmatchable:
            return nil
        case .combo:
            guard event.kind == .flagsChanged else { return nil }
            let required = requiredFlags
            return !required.isEmpty && event.flags.contains(required)
        case .singleModifier(let key):
            guard event.kind == .flagsChanged, event.keyCode == keyCode else { return nil }
            return event.flags.rawValue & key.deviceBit != 0
        case .key:
            guard event.keyCode == keyCode else { return nil }
            switch event.kind {
            case .keyDown: return event.isAutorepeat ? nil : event.flags.contains(requiredFlags)
            case .keyUp: return false
            case .flagsChanged: return nil
            }
        }
    }

    // MARK: - Validation

    /// No main key and no modifiers: can never be triggered.
    var isUnmatchable: Bool {
        if case .unmatchable = form { return true }
        return false
    }

    /// Modifier names that aren't recognised (and so are ignored at runtime).
    var unknownModifiers: [String] { modifiers.filter { Modifier(name: $0) == nil } }

    /// Same key and same modifiers — ignoring order, case and aliases.
    func isSameChord(as other: KeyBinding) -> Bool {
        keyCode == other.keyCode && chordModifiers == other.chordModifiers
    }

    /// Canonical names for recognised modifiers, lowercased raw names otherwise,
    /// so two bindings with the same typo still compare equal.
    private var chordModifiers: Set<String> {
        Set(modifiers.map { Modifier(name: $0)?.rawValue ?? $0.lowercased() })
    }
}

// MARK: - Description

extension KeyBinding: CustomStringConvertible {
    /// Menu/Settings label: "⌃ ⇧", "Right ⌥", "⌃⌥Space".
    var description: String {
        let symbols = resolvedModifiers.map(\.symbol)
        switch form {
        case .unmatchable, .combo: return symbols.joined(separator: " ")
        case .singleModifier(let key): return "\(key.side) \(key.modifier.symbol)"
        case .key: return symbols.joined() + Self.keyName(keyCode)
        }
    }

    private static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case spaceKeyCode: return "Space"
        case escapeKeyCode: return "Esc"
        default: return "key\(keyCode)"
        }
    }
}

// MARK: - Capture

extension KeyBinding {
    /// One live capture session in Settings: fold key events in, get a binding
    /// out. A regular key commits on key-down with whatever modifiers are held;
    /// modifiers alone commit when all are released — two or more as a combo,
    /// one as a single (sided) modifier. Esc cancels.
    struct Capture {
        enum Outcome: Equatable { case pending, cancelled, captured(KeyBinding) }

        /// Peak set of modifiers held during the current attempt.
        private var peak: Set<Modifier> = []
        /// The modifier key that last grew the held set (e.g. Right vs Left ⌥).
        private var lastModifierKeyCode: Int?

        mutating func handle(_ event: KeyEvent) -> Outcome {
            switch event.kind {
            case .keyDown where !event.isAutorepeat:
                if event.keyCode == KeyBinding.escapeKeyCode { return .cancelled }
                guard KeyBinding.modifierKey(event.keyCode) == nil else { return .pending }
                return .captured(KeyBinding(keyCode: event.keyCode,
                                            modifiers: Modifier.held(in: event.flags).map(\.rawValue)))

            case .flagsChanged:
                let held = Set(Modifier.held(in: event.flags))
                if !held.isEmpty {
                    // A release-of-one-while-others-remain doesn't grow the set,
                    // so it mustn't overwrite which key went down.
                    if held.count > peak.count { lastModifierKeyCode = event.keyCode }
                    peak.formUnion(held)
                    return .pending
                }
                guard !peak.isEmpty else { return .pending }
                defer { peak = []; lastModifierKeyCode = nil }
                return commitModifiers().map(Outcome.captured) ?? .pending

            default:
                return .pending
            }
        }

        private func commitModifiers() -> KeyBinding? {
            if peak.count >= 2 { return KeyBinding.combo(Modifier.allCases.filter(peak.contains)) }
            if let keyCode = lastModifierKeyCode, KeyBinding.modifierKey(keyCode) != nil {
                return KeyBinding(keyCode: keyCode, modifiers: [])
            }
            return nil
        }
    }
}
