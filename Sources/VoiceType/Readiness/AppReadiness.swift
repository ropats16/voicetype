import Foundation

/// Everything readiness is computed from.
struct ReadinessInputs: Equatable {
    var accessibility: AccessibilityPermission
    var microphone: MicrophonePermission
    var engine: EngineReadiness
    var hotkeyTap: HotkeyTapHealth
}

/// What the user can do about an issue; the menu, onboarding and overlay map
/// it to a button.
enum ReadinessAction: Equatable {
    case openAccessibilitySettings
    case openMicrophoneSettings
    /// Show the system microphone prompt (only possible while undetermined).
    case requestMicrophone
    /// Where the model file goes, to drop in or re-download one.
    case openModelsFolder
}

/// One reason the app can't dictate (yet).
enum ReadinessIssue: Equatable {
    case accessibilityNeeded
    case microphoneDenied
    case microphoneRestricted
    case microphoneNotDetermined
    case modelMissing(path: String, downloadCommand: String?)
    /// The file exists but wouldn't load, including a checksum mismatch
    /// (`reason` says which).
    case modelFailed(reason: String, downloadCommand: String?)
    case hotkeyTapFailed
    /// Transient: Accessibility is granted and the tap is about to be installed.
    case hotkeysStarting
    /// Transient: a not-yet-checked model file is being hashed.
    case modelVerifying
    /// Transient: the model is loading (or `load()` hasn't run yet).
    case modelLoading

    /// Settles by itself, no user action needed.
    var isTransient: Bool {
        switch self {
        case .hotkeysStarting, .modelVerifying, .modelLoading: return true
        default: return false
        }
    }

    /// Short, for the menu header ("VoiceType — <title>").
    var title: String {
        switch self {
        case .accessibilityNeeded: return "Needs Accessibility"
        case .microphoneDenied, .microphoneNotDetermined: return "Needs Microphone"
        case .microphoneRestricted: return "Microphone restricted"
        case .modelMissing: return "Model missing"
        case .modelFailed: return "Model failed to load"
        case .hotkeyTapFailed: return "Hotkeys unavailable"
        case .hotkeysStarting: return "Starting hotkeys…"
        case .modelVerifying: return "Verifying model…"
        case .modelLoading: return "Loading model…"
        }
    }

    /// One line on how to fix it.
    var detail: String {
        switch self {
        case .accessibilityNeeded:
            return "Allow VoiceType in System Settings › Privacy & Security › Accessibility for hotkeys and pasting."
        case .microphoneDenied:
            return "Turn VoiceType on in System Settings › Privacy & Security › Microphone."
        case .microphoneRestricted:
            return "Microphone access is restricted on this Mac (e.g. by a profile)."
        case .microphoneNotDetermined:
            return "Allow VoiceType to use the microphone."
        case .modelMissing(_, let command):
            return command.map { "Model missing — run `\($0)`" } ?? "Model file missing — see Settings"
        case .modelFailed(_, let command):
            return command.map { "Model failed to load — see log, or try `\($0)` to re-download it" }
                ?? "Model failed to load — see log"
        case .hotkeyTapFailed:
            return "Couldn't install the hotkey listener; retrying. Re-granting Accessibility usually fixes it."
        case .hotkeysStarting:
            return "Installing the hotkey listener."
        case .modelVerifying:
            return "Checking the model file (first use only)."
        case .modelLoading:
            return "Loading the transcription model."
        }
    }

    var action: ReadinessAction? {
        switch self {
        case .accessibilityNeeded, .hotkeyTapFailed: return .openAccessibilitySettings
        case .microphoneDenied, .microphoneRestricted: return .openMicrophoneSettings
        case .microphoneNotDetermined: return .requestMicrophone
        case .modelMissing, .modelFailed: return .openModelsFolder
        case .hotkeysStarting, .modelVerifying, .modelLoading: return nil
        }
    }
}

/// The one app-wide readiness value the menu (and later onboarding and the
/// overlay) render.
enum AppStatus: Equatable {
    case ready
    /// Will settle by itself; `issue.isTransient`.
    case starting(ReadinessIssue)
    /// Needs the user; `!issue.isTransient`.
    case notReady(ReadinessIssue)

    var issue: ReadinessIssue? {
        switch self {
        case .ready: return nil
        case .starting(let issue), .notReady(let issue): return issue
        }
    }

    var title: String { issue?.title ?? "Ready" }

    /// Whether a hotkey press should start a recording. A loading or
    /// verifying model doesn't block it (the job queues behind the load);
    /// anything else does — notably a denied mic, which would record silence.
    var allowsDictation: Bool {
        switch self {
        case .ready, .starting(.modelLoading), .starting(.modelVerifying): return true
        default: return false
        }
    }
}

/// Pure: inputs → issues → status.
///
/// Priority (first applicable wins; `issues(for:)` lists them in this order):
///  1. Accessibility needed — nothing works without it (no tap, no paste).
///  2. Microphone denied / restricted / not determined (mutually exclusive).
///  3. Model missing.
///  4. Model failed to load (incl. checksum mismatch).
///  5. Hotkey tap failed (only with Accessibility granted).
///  — transient, shown only when nothing above applies —
///  6. Hotkeys starting (Accessibility granted, tap not installed yet).
///  7. Model verifying.
///  8. Model loading.
///
/// Actionable before transient: the user can fix a permission while the model
/// loads. Permissions before the model: they're the first-run steps, in
/// onboarding order. A tap issue is never shown while Accessibility is
/// denied: one cause, one reason.
enum AppReadiness {
    static func issues(for inputs: ReadinessInputs) -> [ReadinessIssue] {
        var issues: [ReadinessIssue] = []
        let engine = inputs.engine
        let axGranted = inputs.accessibility == .granted

        if !axGranted { issues.append(.accessibilityNeeded) }

        switch inputs.microphone {
        case .authorized: break
        case .denied: issues.append(.microphoneDenied)
        case .restricted: issues.append(.microphoneRestricted)
        case .notDetermined: issues.append(.microphoneNotDetermined)
        }

        switch engine.status {
        case .missing:
            issues.append(.modelMissing(path: engine.modelPath, downloadCommand: engine.downloadCommand))
        case .failed(let reason):
            issues.append(.modelFailed(reason: reason, downloadCommand: engine.downloadCommand))
        case .notLoaded, .verifying, .loading, .ready:
            break
        }

        if axGranted && inputs.hotkeyTap == .failed { issues.append(.hotkeyTapFailed) }

        if axGranted && inputs.hotkeyTap == .notInstalled { issues.append(.hotkeysStarting) }

        switch engine.status {
        case .verifying: issues.append(.modelVerifying)
        case .notLoaded, .loading: issues.append(.modelLoading)
        case .missing, .failed, .ready: break
        }

        return issues
    }

    static func status(for inputs: ReadinessInputs) -> AppStatus {
        guard let top = issues(for: inputs).first else { return .ready }
        return top.isTransient ? .starting(top) : .notReady(top)
    }
}
