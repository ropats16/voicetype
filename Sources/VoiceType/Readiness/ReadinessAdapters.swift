import Foundation

/// The live probe: TCC microphone status and `AXIsProcessTrusted`.
extension Permissions: PermissionProbe {
    var accessibility: AccessibilityPermission {
        isAccessibilityTrusted() ? .granted : .denied
    }

    // `microphone` is `Permissions.microphone`.
}

extension EngineReadiness {
    /// The engine as it is now. Read live rather than from the status just
    /// pushed: after a failed switch the engine is already back on the
    /// previous model, and a re-download hint must not name the wrong file.
    /// The hint comes from the model's own engine (`engines`).
    init(_ engine: TranscriptionEngine, engines: EngineRegistry = .shared) {
        let model = engine.model
        self.init(status: engine.status, modelPath: model.path, download: engines.downloadHint(for: model))
    }
}
