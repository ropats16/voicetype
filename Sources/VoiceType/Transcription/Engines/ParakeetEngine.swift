import Foundation

/// Parakeet TDT v3 (via FluidAudio) as an `EngineDescriptor`: the opt-in
/// "Turbo (English/EU)" engine. Apple Silicon only (it runs on the Neural
/// Engine) and only for its 25 European languages or auto-detect. A model is
/// a folder, `<models>/parakeet/<id>`, fetched by `make parakeet-model` and
/// verified file by file when the adapter loads it.
struct ParakeetEngine: EngineDescriptor {
    let kind = EngineKind.parakeet

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        environment.hardware.isAppleSilicon ? .available : .unavailable(reason: "Turbo needs Apple Silicon")
    }

    /// The catalog's languages plus auto-detect (v3 detects among its own).
    var supportedLanguages: Set<String>? {
        Set(ParakeetCatalog.models.flatMap(\.languages)).union([ModelSpec.autoDetect])
    }

    var models: [EngineModelOption] {
        ParakeetCatalog.models.map { EngineModelOption(id: $0.id, label: $0.label) }
    }

    /// Automatic is the catalog default; a named id is its folder (an id not
    /// in the catalog too, which then reports missing). `sha256` is nil: the
    /// adapter checks a catalog folder's files itself.
    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        let id: String
        switch choice {
        case .automatic: id = ParakeetCatalog.defaultModel.id
        case .named(let named): id = named
        }
        let folder = ParakeetCatalog.directory(in: context.modelsDir).appendingPathComponent(id, isDirectory: true)
        return ModelSpec(path: folder.path, sha256: nil, language: context.language, engine: kind)
    }

    /// A catalog folder must hold every pinned file (so a partial copy shows
    /// the download hint rather than a failed load); any other folder just
    /// has to exist. No hashing here: that's the load's job.
    func isPresent(_ spec: ModelSpec) -> Bool {
        guard let model = ParakeetCatalog.model(forFolder: spec.path) else {
            return FileManager.default.fileExists(atPath: spec.path)
        }
        return model.firstMissingFile(in: URL(fileURLWithPath: spec.path, isDirectory: true)) == nil
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        .command("make parakeet-model")
    }

    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        ModelSpec(path: (argument as NSString).expandingTildeInPath, sha256: nil,
                  language: language.isEmpty ? ModelSpec.autoDetect : language, engine: kind)
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.parakeetAdapter()
    }

    let acknowledgement = """
        Parakeet TDT 0.6B v3 by NVIDIA (CC BY 4.0), converted to Core ML by FluidInference. \
        FluidAudio by FluidInference (Apache 2.0).
        """
}
