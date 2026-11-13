import Foundation

/// An engine whose models are catalog folders (`FolderModelCatalog`):
/// WhisperKit and Parakeet. They share every model rule; each states only its
/// catalog, its Automatic pick and its download command.
///
/// - A named id resolves to `<models>/<subdirectory>/<id>/`, Automatic to
///   `automaticModel(in:)`'s folder. A catalog folder's spec carries the
///   pinned manifest digest, so `TranscriptionEngine` verifies every file
///   (reporting `.verifying`) before the adapter loads it. An id or path that
///   isn't in the catalog resolves unverified, like a custom whisper file.
/// - A catalog folder is present once its manifest is there: the download
///   writes it last and only then renames the folder into place, so a
///   partial copy shows the download hint rather than a failed load. Any
///   other folder just has to exist. No hashing here: that's the load's job.
/// - A catalog model downloads in-app (Settings' Download button,
///   `FolderModelDownloader`) from the same pinned files as its command.
protocol FolderModelEngine: EngineDescriptor {
    associatedtype Catalog: FolderModelCatalog

    /// What Automatic loads for this language and Mac.
    func automaticModel(in context: ModelContext) -> Catalog.Model

    /// The command that downloads `model`, e.g. `make whisperkit-model WHISPERKIT=tiny.en`.
    func downloadCommand(for model: Catalog.Model) -> String
}

extension FolderModelEngine {
    var models: [EngineModelOption] {
        Catalog.models.map { EngineModelOption(id: $0.id, label: $0.label) }
    }

    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        let id: String
        switch choice {
        case .automatic: id = automaticModel(in: context).id
        case .named(let named): id = named
        }
        return spec(folder: Catalog.folder(for: id, in: context.modelsDir).path, language: context.language)
    }

    func isPresent(_ spec: ModelSpec) -> Bool {
        guard Catalog.model(forFolder: spec.path) != nil else {
            return FileManager.default.fileExists(atPath: spec.path)
        }
        let manifest = URL(fileURLWithPath: spec.path).appendingPathComponent(ModelVerifier.folderManifestName)
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// The catalog model's command; nil for a custom folder (nothing to fetch).
    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        Catalog.model(forFolder: spec.path).map { .command(downloadCommand(for: $0)) }
    }

    /// A catalog model's pinned files, into the folder `resolve` gives it.
    func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload? {
        let files = Catalog.pinnedFiles(for: id)
        guard !files.isEmpty else { return nil }
        return ModelDownload(modelID: id, files: files, destination: Catalog.folder(for: id, in: modelsDir))
    }

    /// Verified against the pinned manifest when it's a catalog folder.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        spec(folder: (argument as NSString).expandingTildeInPath,
             language: language.isEmpty ? ModelSpec.autoDetect : language)
    }

    private func spec(folder: String, language: String) -> ModelSpec {
        ModelSpec(path: folder, sha256: Catalog.model(forFolder: folder)?.manifestSHA256,
                  language: language, engine: kind)
    }
}
