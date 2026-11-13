import Foundation

/// One downloadable Parakeet model: a folder of compiled Core ML models plus
/// the vocabulary, pinned file by file to an exact Hugging Face revision.
struct ParakeetModel: Hashable, Identifiable {
    /// One file of the model folder, pinned like a whisper model.
    struct File: Hashable {
        /// Relative to the model folder (and to the repo root), e.g.
        /// `Encoder.mlmodelc/weights/weight.bin`.
        let path: String
        let bytes: Int64
        /// Lowercase hex SHA-256 of the file.
        let sha256: String
    }

    /// The folder name under `models/parakeet/`, e.g. `parakeet-tdt-0.6b-v3`.
    let id: String
    /// The Hugging Face repo the files come from.
    let repo: String
    /// The pinned commit of `repo`; files are fetched from it, never `main`.
    let revision: String
    /// ISO 639-1 codes it transcribes.
    let languages: [String]
    /// Every file the adapter loads; nothing else is downloaded.
    let files: [File]

    /// Total download size in bytes.
    var bytes: Int64 { files.map(\.bytes).reduce(0, +) }

    /// e.g. "parakeet-tdt-0.6b-v3 (482 MB)".
    var label: String { "\(id) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }

    /// Whether it can transcribe `language` (an ISO code, any case), or
    /// auto-detect (`ModelSpec.autoDetect`), which it does among its own
    /// languages.
    func supports(language: String) -> Bool {
        let code = language.lowercased()
        return code == ModelSpec.autoDetect || languages.contains(code)
    }

    /// Where it lives: `<models>/parakeet/<id>`, the folder
    /// `scripts/download_parakeet_model.sh` fills.
    func folder(in modelsDir: URL = Paths.modelsDir) -> URL {
        ParakeetCatalog.directory(in: modelsDir).appendingPathComponent(id, isDirectory: true)
    }

    /// Throws unless `folder` holds every pinned file, byte for byte:
    /// `ParakeetModelIncomplete` for the first missing file (checked before
    /// any hashing), `ModelChecksumMismatch` (named by relative path) for the
    /// first one that differs. Hashes go through `verifier`, so its cache
    /// makes a re-check of an unchanged folder cheap. `willHash` runs before
    /// the first file that must actually be hashed.
    func verify(folder: URL, verifier: ModelVerifier, willHash: () -> Void = {}) throws {
        if let missing = files.first(where: {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).path)
        }) {
            throw ParakeetModelIncomplete(model: id, missing: missing.path)
        }
        var announced = false
        for file in files {
            do {
                try verifier.verify(path: folder.appendingPathComponent(file.path).path, sha256: file.sha256) {
                    if !announced { announced = true; willHash() }
                }
            } catch is ModelChecksumMismatch {
                throw ModelChecksumMismatch(filename: file.path)
            }
        }
    }
}

/// A Parakeet model folder missing one of its files (an interrupted or
/// partial copy; the download script never leaves one under the final name).
struct ParakeetModelIncomplete: LocalizedError, Equatable {
    let model: String
    /// The first missing file, relative to the folder.
    let missing: String

    var errorDescription: String? {
        "The \(model) model folder is incomplete (no \(missing)). Run `make parakeet-model` to finish the download."
    }
}

/// Every Parakeet model the app knows, with pinned per-file checksums. Pure:
/// no filesystem access (`ParakeetModel.verify` does that).
///
/// `scripts/parakeet_catalog.sh` mirrors `models` for the download script;
/// `ParakeetCatalogScriptParityTests` keeps them in step.
enum ParakeetCatalog {

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
            files: [
                .init(path: "parakeet_vocab.json", bytes: 151122,
                      sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
                .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243,
                      sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                .init(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486,
                      sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                .init(path: "Preprocessor.mlmodelc/metadata.json", bytes: 2841,
                      sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                .init(path: "Preprocessor.mlmodelc/model.mil", bytes: 28181,
                      sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                .init(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491072,
                      sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
                      sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
                .init(path: "Encoder.mlmodelc/coremldata.bin", bytes: 485,
                      sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
                .init(path: "Encoder.mlmodelc/metadata.json", bytes: 2921,
                      sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
                .init(path: "Encoder.mlmodelc/model.mil", bytes: 959769,
                      sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
                .init(path: "Encoder.mlmodelc/weights/weight.bin", bytes: 445187200,
                      sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
                .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243,
                      sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
                .init(path: "Decoder.mlmodelc/coremldata.bin", bytes: 554,
                      sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
                .init(path: "Decoder.mlmodelc/metadata.json", bytes: 3427,
                      sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
                .init(path: "Decoder.mlmodelc/model.mil", bytes: 13110,
                      sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
                .init(path: "Decoder.mlmodelc/weights/weight.bin", bytes: 23604992,
                      sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
                .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243,
                      sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
                .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521,
                      sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
                .init(path: "JointDecisionv3.mlmodelc/metadata.json", bytes: 3453,
                      sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
                .init(path: "JointDecisionv3.mlmodelc/model.mil", bytes: 11775,
                      sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
                .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12642764,
                      sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            ]),
    ]

    /// The model the app offers (the only one, for now).
    static var defaultModel: ParakeetModel { models[0] }

    static func model(id: String) -> ParakeetModel? {
        models.first { $0.id == id }
    }

    /// The catalog model whose id is the last component of `path` (a model
    /// folder); nil for a custom folder.
    static func model(forFolder path: String) -> ParakeetModel? {
        guard !path.isEmpty else { return nil }
        return model(id: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// Whether any Parakeet model transcribes `language` (or auto-detects):
    /// the engine registry shows Parakeet only then.
    static func supports(language: String) -> Bool {
        models.contains { $0.supports(language: language) }
    }

    /// `<models>/parakeet`: every Parakeet model folder lives here.
    static func directory(in modelsDir: URL = Paths.modelsDir) -> URL {
        modelsDir.appendingPathComponent("parakeet", isDirectory: true)
    }
}
