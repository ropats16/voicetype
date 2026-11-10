import Foundation

// The seams between `ReadinessMonitor` and the rest of the app: what the
// permissions are (polled), what the engine is doing and whether the hotkey
// tap is up (both pushed in). Tests drive the monitor with fakes of all of
// them. Main thread only.

enum AccessibilityPermission: Equatable { case granted, denied }

enum MicrophonePermission: Equatable { case authorized, denied, restricted, notDetermined }

/// Reads the permissions the app needs. Cheap: polled every few seconds.
protocol PermissionProbe: AnyObject {
    var accessibility: AccessibilityPermission { get }
    var microphone: MicrophonePermission { get }
}

/// What readiness needs to know about the engine: its status, and enough
/// about its model to tell the user how to fix a missing or broken file.
struct EngineReadiness: Equatable {
    var status: TranscriptionStatus
    var modelPath: String
    /// The command that downloads the model; nil for a custom file.
    var downloadCommand: String?
}

/// The global hotkey tap. `HotkeyManager.start()` only says installed or not;
/// a tap the system disables is re-enabled inside the manager, so it never
/// shows up here.
enum HotkeyTapHealth: Equatable {
    /// No tap yet: not attempted, or presumed dead after Accessibility was
    /// revoked.
    case notInstalled
    case installed
    /// The last install attempt failed.
    case failed
}
