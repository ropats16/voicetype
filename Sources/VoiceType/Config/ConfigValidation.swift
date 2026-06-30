import Foundation

/// A single problem found in a `Config`. Reporting only — see `ConfigValidator`.
struct ConfigIssue: Equatable {
    enum Severity { case error, warning }
    let severity: Severity
    let message: String
}

/// Pure, side-effect-free validation of a `Config`. Detects invalid or
/// conflicting key bindings (plus a sanity check on max recording duration) so
/// the app can report them clearly at startup. It never mutates the config; it
/// only inspects and returns an ordered list of problems (errors first, then
/// warnings).
enum ConfigValidator {
    /// Modifier names understood at runtime — mirrors `HotkeyManager.flags(for:)`.
    /// Anything outside this set is silently dropped when the tap evaluates
    /// flags, so we surface it as a warning rather than failing silently.
    private static let knownModifiers: Set<String> = [
        "command", "cmd", "option", "alt", "control", "ctrl",
        "shift", "function", "fn", "globe",
    ]

    static func validate(_ config: Config) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        // error — hold and toggle resolve to the same chord, so both modes
        // would fire on the same key.
        if bindingsMatch(config.hold, config.toggle) {
            issues.append(ConfigIssue(
                severity: .error,
                message: "`hold` and `toggle` are the same binding (\(HotkeyDescription.describe(config.hold))); both modes would trigger on the same key."))
        }

        // error — a binding with no key and no modifiers can never match.
        if isUnmatchable(config.hold) {
            issues.append(ConfigIssue(
                severity: .error,
                message: "`hold` binding is empty (keyCode < 0 with no modifiers); it can never match."))
        }
        if isUnmatchable(config.toggle) {
            issues.append(ConfigIssue(
                severity: .error,
                message: "`toggle` binding is empty (keyCode < 0 with no modifiers); it can never match."))
        }

        // warning — the cancel (Esc) key shares a real key code with a binding.
        if config.hold.keyCode >= 0, config.cancelKeyCode == config.hold.keyCode {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`cancelKeyCode` (\(config.cancelKeyCode)) collides with the `hold` key code; cancel may shadow hold-to-talk."))
        }
        if config.toggle.keyCode >= 0, config.cancelKeyCode == config.toggle.keyCode {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`cancelKeyCode` (\(config.cancelKeyCode)) collides with the `toggle` key code; cancel may shadow toggle."))
        }

        // warning — modifier names the runtime won't recognise (and so ignores).
        for name in unknownModifiers(in: config.hold.modifiers) {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`hold` has unknown modifier \"\(name)\"; it will be ignored."))
        }
        for name in unknownModifiers(in: config.toggle.modifiers) {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`toggle` has unknown modifier \"\(name)\"; it will be ignored."))
        }

        // warning — non-positive max duration disables auto-stop (0 = no cap).
        if config.maxRecordingSeconds <= 0 {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`maxRecordingSeconds` is \(config.maxRecordingSeconds); recording auto-stop is disabled."))
        }

        return issues
    }

    // MARK: - Helpers

    /// Two bindings match the same chord when their key codes are equal and
    /// their modifier sets are equal — order- and case-insensitive, matching
    /// how `HotkeyManager.flags(for:)` interprets modifier names at runtime.
    private static func bindingsMatch(_ a: KeyBinding, _ b: KeyBinding) -> Bool {
        a.keyCode == b.keyCode && modifierSet(a.modifiers) == modifierSet(b.modifiers)
    }

    /// A binding with no main key and no modifiers can never be triggered.
    private static func isUnmatchable(_ binding: KeyBinding) -> Bool {
        binding.keyCode < 0 && binding.modifiers.isEmpty
    }

    private static func unknownModifiers(in modifiers: [String]) -> [String] {
        modifiers.filter { !knownModifiers.contains($0.lowercased()) }
    }

    private static func modifierSet(_ modifiers: [String]) -> Set<String> {
        Set(modifiers.map { $0.lowercased() })
    }
}
