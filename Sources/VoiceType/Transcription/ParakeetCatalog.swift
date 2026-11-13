import Foundation

/// One downloadable Parakeet model: a folder of compiled Core ML models plus
/// the vocabulary, pinned file by file to an exact Hugging Face revision.
struct ParakeetModel: FolderModel, Hashable, Identifiable {
    /// The folder name under `models/parakeet/`, e.g. `parakeet-tdt-0.6b-v3`.
    let id: String
    /// The Hugging Face repo the files come from.
    let repo: String
    /// The pinned commit of `repo`; files are fetched from it, never `main`.
    let revision: String
    /// ISO 639-1 codes it transcribes.
    let languages: [String]
    /// All files' sizes, in bytes.
    let bytes: Int64
    /// Lowercase hex SHA-256 of the folder's manifest (see `ModelVerifier.verifyFolder`).
    let manifestSHA256: String

    /// e.g. "parakeet-tdt-0.6b-v3 (483 MB)".
    var label: String { "\(id) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }
}

/// Every Parakeet model the app knows, each pinned by its manifest digest,
/// like `WhisperKitCatalog`. Pure: no filesystem access.
///
/// `scripts/parakeet_files.tsv` lists every file with its size and SHA-256
/// for `scripts/download_parakeet_model.sh`, which writes the manifest;
/// `ParakeetCatalogTests` checks the table adds up to the digests here.
enum ParakeetCatalog: FolderModelCatalog {
    static let subdirectory = "parakeet"

    /// v3 rather than v2: v2 is English-only and only slightly ahead on
    /// English WER, while v3 adds 24 European languages (the "Turbo
    /// (English/EU)" engine) for the same size and speed. The default int8
    /// encoder (`Encoder.mlmodelc`, what FluidAudio loads by default); the
    /// repo's other encoders, joints and `.mlpackage` sources aren't fetched.
    static let models: [ParakeetModel] = [
        ParakeetModel(
            id: "parakeet-tdt-0.6b-v3",
            repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
            // NVIDIA's model card: the 25 European languages.
            languages: ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"],
            bytes: 483_105_645,
            manifestSHA256: "66e79161c28717a7869b552453eab474975e801ba5dee28a964d79f952690dff"),
    ]

    /// The model the app offers (the only one, for now).
    static var defaultModel: ParakeetModel { models[0] }
}
