import Foundation

/// A notification (and its log line) for a model problem the engine reported.
struct ModelNotice: Equatable {
    var title: String
    var body: String
    var log: String
}

/// The model-problem wording, in one place: the menu's one-liner
/// (`ReadinessIssue.detail`) and the notice posted when the engine reports a
/// missing or broken model. How to get the model comes from its engine
/// (`EngineDescriptor.downloadHint`): a command (whisper's `make model`) is
/// quoted to run; instructions (an engine whose models aren't files fetched
/// by command) are shown as written, with no file path assumed.
enum ModelHints {
    /// Menu line for a missing model.
    static func missing(download: ModelDownloadHint?) -> String {
        switch download {
        case .command(let command)?: return "Model missing — run `\(command)`"
        case .instructions(let text)?: return "Model missing — \(text)"
        case nil: return "Model file missing — see Settings"
        }
    }

    /// Menu line for a model that wouldn't load.
    static func failed(download: ModelDownloadHint?) -> String {
        switch download {
        case .command(let command)?: return "Model failed to load — see log, or try `\(command)` to re-download it"
        case .instructions, nil: return "Model failed to load — see log"
        }
    }

    /// The notice for a status the engine just reported; nil when it needs
    /// none. `engine` is the engine as it is now (read live, see
    /// `EngineReadiness.init(_:)`): after a failed switch it's already back on
    /// the previous model, so no re-download hint — it would name the wrong
    /// model.
    static func notice(for reported: TranscriptionStatus, engine: EngineReadiness) -> ModelNotice? {
        switch reported {
        case .missing:
            switch engine.download {
            case .instructions(let text)?:
                return ModelNotice(title: "VoiceType: model not installed", body: text,
                                   log: "Model not installed (\(engine.modelPath)). \(text)")
            case .command, nil:
                let fix = command(engine.download).map { " Run `\($0)` to download it." } ?? ""
                return ModelNotice(title: "VoiceType: model not found",
                                   body: "Model file not found at \(engine.modelPath).\(fix)",
                                   log: "Model not found at \(engine.modelPath).\(fix)")
            }
        case .failed(let reason):
            let fix: String
            switch redownload(engine) {
            case .command(let command)?: fix = " Try `\(command)` to re-download it."
            case .instructions(let text)?: fix = " \(text)"
            case nil: fix = ""
            }
            return ModelNotice(title: "VoiceType: model failed to load", body: "\(reason)\(fix)",
                               log: "Model load failed: \(reason)")
        case .notLoaded, .verifying, .loading, .ready:
            return nil
        }
    }

    private static func command(_ hint: ModelDownloadHint?) -> String? {
        if case .command(let command)? = hint { return command }
        return nil
    }

    /// The download hint, only while the engine is still failed.
    private static func redownload(_ engine: EngineReadiness) -> ModelDownloadHint? {
        if case .failed = engine.status { return engine.download }
        return nil
    }
}
