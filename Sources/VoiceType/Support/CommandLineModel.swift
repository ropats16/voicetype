import Foundation

extension EngineDescriptor {
    /// The model `--bench` and `--selftest` load: `--model <argument>`'s spec
    /// (`spec(forModelArgument:language:)`, taken as given, so a missing one
    /// reports missing on load as before), or with no `--model` the engine's
    /// Automatic pick in `context`, which must be installed — else
    /// `AutomaticModelMissing`, with the engine's download hint. So an engine
    /// without model files (apple-speech) needs no `--model` at all.
    func commandLineSpec(modelArgument: String?, in context: ModelContext) throws -> ModelSpec {
        if let argument = modelArgument {
            return spec(forModelArgument: argument, language: context.language)
        }
        let spec = resolve(.automatic, in: context)
        guard isPresent(spec) else {
            throw AutomaticModelMissing(engine: kind, path: spec.path, hint: downloadHint(for: spec))
        }
        return spec
    }
}

/// No `--model` was given and the engine's Automatic pick isn't installed.
struct AutomaticModelMissing: LocalizedError {
    let engine: EngineKind
    let path: String
    let hint: ModelDownloadHint?

    var errorDescription: String? {
        let fix: String
        switch hint {
        case .command(let command)?: fix = "run `\(command)`, or pass --model"
        case .instructions(let text)?: fix = text
        case nil: fix = "pass --model"
        }
        return "no --model given, and \(engine.displayName)'s Automatic model (\(path)) isn't installed — \(fix)"
    }
}
