import Foundation

/// One downloadable WhisperKit model: a folder of Core ML models (`.mlmodelc`)
/// plus the matching OpenAI tokenizer, pinned file by file.
struct WhisperKitModel: FolderModel, Hashable, Identifiable {
    /// The local folder name: the Hugging Face folder minus `openai_whisper-`,
    /// e.g. `small.en_217MB`. What `make whisperkit-model WHISPERKIT=` takes.
    let id: String
    /// What the user sees, e.g. `large-v3-turbo` for `large-v3-v20240930`.
    let name: String
    /// All files' sizes, in bytes.
    let bytes: Int64
    /// Lowercase hex SHA-256 of the folder's manifest (see `ModelVerifier.verifyFolder`).
    let manifestSHA256: String

    /// `.en` models only transcribe English; the rest take any language.
    var isEnglishOnly: Bool { id.contains(".en") }

    /// e.g. "small.en, compressed (220 MB)".
    var label: String { "\(name) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }
}

/// The WhisperKit models the app offers, each pinned to one commit of
/// huggingface.co/argmaxinc/whisperkit-coreml (tokenizers to one commit of
/// the matching `openai/whisper-*` repo). Pure: no filesystem access.
///
/// `scripts/whisperkit_files.tsv` lists every file with its size and SHA-256
/// for `scripts/download_whisperkit_model.sh`; `WhisperKitCatalogTests`
/// checks it adds up to the digests here. Regenerate both with
/// `scripts/pin_whisperkit_models.py`.
enum WhisperKitCatalog: FolderModelCatalog {
    static let subdirectory = "whisperkit"
    static let repo = "argmaxinc/whisperkit-coreml"
    static let revision = "0f63a7800b00dd0226abd051b906c246e1907482"

    /// Smallest first; English-only before multilingual.
    static let models: [WhisperKitModel] = [
        WhisperKitModel(id: "tiny.en", name: "tiny.en", bytes: 79029625,
                        manifestSHA256: "2e9adcc9fb06e8d0ac36f3c0db4a54fe4cc53fa9629edfebe09b76e8c7c2738f"),
        WhisperKitModel(id: "tiny", name: "tiny", bytes: 79398546,
                        manifestSHA256: "aaae17bde66fa9328a009bd9dbc826dd73d65937050ed3d50768bdddfe639f12"),
        WhisperKitModel(id: "base.en", name: "base.en", bytes: 149114215,
                        manifestSHA256: "a4d59fcfe3e7621892c0f0f31773a1ee38e9d32b5d38165fd8bbb3716a795b87"),
        WhisperKitModel(id: "base", name: "base", bytes: 149482602,
                        manifestSHA256: "1f26d34b5a337a0523639704a5c67b5869cfe4983c9f62b826b7c7ffdbdb60c6"),
        WhisperKitModel(id: "small.en_217MB", name: "small.en, compressed", bytes: 220284892,
                        manifestSHA256: "1c8ae3a474bca8b57c555d8330f4216b14aacb65b0ea8a3e808536f7210394f6"),
        WhisperKitModel(id: "small.en", name: "small.en", bytes: 488917446,
                        manifestSHA256: "8c08e5035d86f816d1873f544e204b298ae545ba063e38d1cdf3e3837d757c27"),
        WhisperKitModel(id: "small", name: "small", bytes: 489250614,
                        manifestSHA256: "1b8058a5fe42e1533d80e2591b531ade25f115d29d106eea3cebbd7a2324cdda"),
        WhisperKitModel(id: "large-v3-v20240930_626MB", name: "large-v3-turbo, compressed", bytes: 629481698,
                        manifestSHA256: "bfb34aee9b4c5f60e844f59a87118c0c02a4df7667b3e90c1b2a59e26948b330"),
        WhisperKitModel(id: "large-v3-v20240930", name: "large-v3-turbo", bytes: 1622294723,
                        manifestSHA256: "e9d304611180d0e8cb353710b5426afce980427aec0f3b054a2002249e0561a6"),
    ]

    /// The Automatic pick: the compressed small.en for English (a dictation-
    /// speed model, 220 MB); the compressed large-v3-turbo for any other
    /// language or auto-detect, where small multilingual models are weak.
    static func defaultModel(language: String) -> WhisperKitModel {
        model(id: ModelCatalog.isEnglish(language) ? "small.en_217MB" : "large-v3-v20240930_626MB")!
    }
}
