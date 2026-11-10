import Foundation

/// A notification (and its log line) for a model problem the engine reported.
struct ModelNotice: Equatable {
    var title: String
    var body: String
    var log: String
}

/// The model-problem wording, in one place: the menu's one-liner
/// (`ReadinessIssue.detail`) and the notice posted when the engine reports a
/// missing or broken model.
enum ModelHints {
    /// Menu line for a missing model file.
    static func missing(downloadCommand: String?) -> String {
        downloadCommand.map { "Model missing — run `\($0)`" } ?? "Model file missing — see Settings"
    }

    /// Menu line for a model that wouldn't load.
    static func failed(downloadCommand: String?) -> String {
        downloadCommand.map { "Model failed to load — see log, or try `\($0)` to re-download it" }
            ?? "Model failed to load — see log"
    }

    /// The notice for a status the engine just reported; nil when it needs
    /// none. `engine` is the engine as it is now (read live, see
    /// `EngineReadiness.init(_:)`): after a failed switch it's already back on
    /// the previous model, so no re-download hint — it would name the wrong
    /// file.
    static func notice(for reported: TranscriptionStatus, engine: EngineReadiness) -> ModelNotice? {
        switch reported {
        case .missing:
            let fix = engine.downloadCommand.map { " Run `\($0)` to download it." } ?? ""
            return ModelNotice(title: "VoiceType: model not found",
                               body: "Model file not found at \(engine.modelPath).\(fix)",
                               log: "Model not found at \(engine.modelPath).\(fix)")
        case .failed(let reason):
            let fix = redownloadCommand(engine).map { " Try `\($0)` to re-download it." } ?? ""
            return ModelNotice(title: "VoiceType: model failed to load", body: "\(reason)\(fix)",
                               log: "Model load failed: \(reason)")
        case .notLoaded, .verifying, .loading, .ready:
            return nil
        }
    }

    /// The download command, only while the engine is still failed.
    private static func redownloadCommand(_ engine: EngineReadiness) -> String? {
        if case .failed = engine.status { return engine.downloadCommand }
        return nil
    }
}
