import Foundation

/// The live probe: TCC microphone status and `AXIsProcessTrusted`.
extension Permissions: PermissionProbe {
    var accessibility: AccessibilityPermission {
        isAccessibilityTrusted() ? .granted : .denied
    }

    var microphone: MicrophonePermission {
        switch micStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        }
    }
}

extension EngineReadiness {
    /// The engine as it is now. Read live rather than from the status just
    /// pushed: after a failed switch the engine is already back on the
    /// previous model, and a re-download hint must not name the wrong file.
    init(_ engine: TranscriptionEngine) {
        let model = engine.model
        self.init(status: engine.status, modelPath: model.path,
                  downloadCommand: ModelSelection.downloadCommand(for: model))
    }
}
