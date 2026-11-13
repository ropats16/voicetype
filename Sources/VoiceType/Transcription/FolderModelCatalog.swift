import Foundation

/// A model that is a folder of files (Core ML models, a vocabulary), not one
/// file: WhisperKit's and Parakeet's. The download script writes a manifest
/// into the folder and the catalog pins the manifest's SHA-256, so one digest
/// covers every file (`ModelVerifier.verifyFolder`).
protocol FolderModel {
    /// The folder's name, and what `ModelChoice.named` stores.
    var id: String { get }
    /// e.g. "small.en, compressed (220 MB)".
    var label: String { get }
    /// Lowercase hex SHA-256 of the folder's manifest.
    var manifestSHA256: String { get }
}

/// A pinned list of folder models living in `<models>/<subdirectory>/<id>/`.
/// Conformers are namespaces (enums) with static data; the lookups and paths
/// are shared here so each engine's catalog is only its table. Pure: no
/// filesystem access.
protocol FolderModelCatalog {
    associatedtype Model: FolderModel
    /// The folder under the models directory, e.g. `whisperkit`.
    static var subdirectory: String { get }
    /// In Settings' order.
    static var models: [Model] { get }
    /// Every file of model `id`, for the in-app download (`FolderModelPins`);
    /// empty for an id not in the catalog.
    static func pinnedFiles(for id: String) -> [PinnedFile]
}

extension FolderModelCatalog {
    static func model(id: String) -> Model? {
        models.first { $0.id == id }
    }

    /// The catalog model whose id is the folder's name (wherever it lives);
    /// nil for a custom folder.
    static func model(forFolder path: String) -> Model? {
        guard !path.isEmpty else { return nil }
        return model(id: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// `<models>/<subdirectory>/`, beside the whisper.cpp files.
    static func directory(in modelsDir: URL = Paths.modelsDir) -> URL {
        modelsDir.appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// Where model `id` is downloaded to: `<models>/<subdirectory>/<id>/`.
    static func folder(for id: String, in modelsDir: URL = Paths.modelsDir) -> URL {
        directory(in: modelsDir).appendingPathComponent(id, isDirectory: true)
    }
}
