import Foundation

/// WhisperKit (Core ML; encoder and decoder on the Neural Engine) as an
/// `EngineDescriptor`. Apple Silicon only (Intel has no Neural Engine; Core
/// ML would fall back to the CPU). Any language whisper takes, auto-detect
/// included, with a multilingual model. A model is a folder,
/// `<models>/whisperkit/<id>`, fetched by `make whisperkit-model`; a catalog
/// folder's spec carries its pinned manifest digest, so the engine verifies
/// every file (`ModelVerifier.verifyFolder`) before loading, reporting
/// `.verifying` while it hashes.
struct WhisperKitEngine: EngineDescriptor {
    let kind = EngineKind.whisperKit

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        environment.hardware.isAppleSilicon ? .available : .unavailable(reason: "WhisperKit needs Apple Silicon")
    }

    var models: [EngineModelOption] {
        WhisperKitCatalog.models.map { EngineModelOption(id: $0.id, label: $0.label) }
    }

    /// Automatic is `WhisperKitCatalog.defaultModel(language:)`; a named id
    /// is its folder (an id not in the catalog too: unverified, and it then
    /// reports missing or loads as a custom folder).
    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        let id: String
        switch choice {
        case .automatic: id = WhisperKitCatalog.defaultModel(language: context.language).id
        case .named(let named): id = named
        }
        let folder = WhisperKitCatalog.folder(for: id, in: context.modelsDir)
        return ModelSpec(path: folder.path, sha256: WhisperKitCatalog.model(id: id)?.manifestSHA256,
                         language: context.language, engine: kind)
    }

    /// A catalog folder counts once its manifest is there: the download
    /// writes it last and only then renames the folder into place, so a
    /// partial copy shows the download hint rather than a failed load. Any
    /// other folder just has to exist. No hashing here: that's the load's job.
    func isPresent(_ spec: ModelSpec) -> Bool {
        guard WhisperKitCatalog.model(forFolder: spec.path) != nil else {
            return FileManager.default.fileExists(atPath: spec.path)
        }
        let manifest = URL(fileURLWithPath: spec.path).appendingPathComponent(ModelVerifier.folderManifestName)
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        WhisperKitCatalog.model(forFolder: spec.path).map { .command("make whisperkit-model WHISPERKIT=\($0.id)") }
    }

    /// Verified against the pinned manifest when it's a catalog folder.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        let path = (argument as NSString).expandingTildeInPath
        return ModelSpec(path: path, sha256: WhisperKitCatalog.model(forFolder: path)?.manifestSHA256,
                         language: language.isEmpty ? ModelSpec.autoDetect : language, engine: kind)
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.whisperKitAdapter()
    }

    let acknowledgement = """
        WhisperKit by Argmax (MIT). Whisper models by OpenAI (MIT), converted to Core ML by Argmax \
        (huggingface.co/argmaxinc/whisperkit-coreml).
        """
}
