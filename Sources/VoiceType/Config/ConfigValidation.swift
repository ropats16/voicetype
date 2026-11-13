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
/// warnings). The per-binding rules live in `KeyBinding`; this only phrases them.
/// It also warns about an `engine` that can't run here (`engines` and
/// `environment` are injectable for tests); the app runs whisper meanwhile.
enum ConfigValidator {
    static func validate(_ config: Config, engines: EngineRegistry = .shared,
                         environment: EngineEnvironment = .current) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        // error — hold and toggle resolve to the same chord, so both modes
        // would fire on the same key.
        if config.hold.isSameChord(as: config.toggle) {
            issues.append(ConfigIssue(
                severity: .error,
                message: "`hold` and `toggle` are the same binding (\(config.hold)); both modes would trigger on the same key."))
        }

        // error — a binding with no key and no modifiers can never match.
        if config.hold.isUnmatchable {
            issues.append(ConfigIssue(
                severity: .error,
                message: "`hold` binding is empty (keyCode < 0 with no modifiers); it can never match."))
        }
        if config.toggle.isUnmatchable {
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
        for name in config.hold.unknownModifiers {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`hold` has unknown modifier \"\(name)\"; it will be ignored."))
        }
        for name in config.toggle.unknownModifiers {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`toggle` has unknown modifier \"\(name)\"; it will be ignored."))
        }

        // warning — an engine that's unknown, not in this build, or can't run
        // on this Mac. Not a language mismatch: that's a Settings choice, and
        // Settings explains that fallback itself. "auto" always runs.
        if config.engineChoice != .automatic,
           case .unavailable(let reason) = engines.availability(ofID: config.engine, in: environment) {
            issues.append(ConfigIssue(
                severity: .warning,
                message: "`engine` \"\(config.engine)\": \(reason); using \(EngineKind.whisper.displayName)."))
        }

        return issues
    }
}
