import Foundation

/// One downloadable whisper.cpp model, pinned to the exact file the app trusts.
struct WhisperModel: Hashable, Identifiable {
    /// The Hugging Face name minus `ggml-`/`.bin`, e.g. `small.en-q5_1`. What
    /// `config.json`'s `model` key and `make model MODEL=` take.
    let id: String
    /// File size in bytes, as published.
    let bytes: Int64
    /// Lowercase hex SHA-256 of the file (the Hugging Face LFS object id).
    let sha256: String

    var filename: String { Self.filename(for: id) }
    /// `.en` models only transcribe English; the rest take any language.
    var isEnglishOnly: Bool { ModelCatalog.isEnglishOnly(id) }

    /// The one filename rule: `ggml-<id>.bin`, as published on Hugging Face.
    static func filename(for id: String) -> String { "ggml-\(id).bin" }
    /// `q5_1`, `q8_0`, … for quantized variants; nil for full precision.
    var quantization: String? {
        guard let dash = id.lastIndex(of: "-"), id[id.index(after: dash)...].hasPrefix("q") else { return nil }
        return String(id[id.index(after: dash)...])
    }

    /// e.g. "small.en-q5_1 (190 MB)".
    var label: String { "\(id) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }
}

/// The chip + RAM facts the auto-pick needs. Injected so the table is testable.
struct HardwareProfile: Equatable {
    /// Whether this build runs on Apple Silicon with Metal (an Intel build,
    /// even under Rosetta, is CPU-only).
    var isAppleSilicon: Bool
    var memoryBytes: UInt64

    /// Whole GiB, rounded down — the same figure `scripts/detect_hardware.sh` uses.
    var memoryGiB: Int { Int(memoryBytes >> 30) }

    static var current: HardwareProfile {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return HardwareProfile(isAppleSilicon: appleSilicon, memoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Every model the app knows, with pinned checksums, plus the hardware
/// auto-pick. Pure: no filesystem access.
///
/// `scripts/model_catalog.sh` mirrors `models` and the auto-pick table for the
/// download/setup scripts; `ModelCatalogScriptParityTests` keeps them in step.
enum ModelCatalog {

    /// Smallest family first; within a family English-only first, then
    /// q5 → q8 → full precision. Sizes and hashes are from
    /// huggingface.co/ggerganov/whisper.cpp.
    static let models: [WhisperModel] = [
        WhisperModel(id: "tiny.en-q5_1", bytes: 32166155,
                     sha256: "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"),
        WhisperModel(id: "tiny.en-q8_0", bytes: 43550795,
                     sha256: "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94"),
        WhisperModel(id: "tiny.en", bytes: 77704715,
                     sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"),
        WhisperModel(id: "tiny-q5_1", bytes: 32152673,
                     sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"),
        WhisperModel(id: "tiny-q8_0", bytes: 43537433,
                     sha256: "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca"),
        WhisperModel(id: "tiny", bytes: 77691713,
                     sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        WhisperModel(id: "base.en-q5_1", bytes: 59721011,
                     sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"),
        WhisperModel(id: "base.en-q8_0", bytes: 81781811,
                     sha256: "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e"),
        WhisperModel(id: "base.en", bytes: 147964211,
                     sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        WhisperModel(id: "base-q5_1", bytes: 59707625,
                     sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
        WhisperModel(id: "base-q8_0", bytes: 81768585,
                     sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9"),
        WhisperModel(id: "base", bytes: 147951465,
                     sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        WhisperModel(id: "small.en-q5_1", bytes: 190098681,
                     sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"),
        WhisperModel(id: "small.en-q8_0", bytes: 264477561,
                     sha256: "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067"),
        WhisperModel(id: "small.en", bytes: 487614201,
                     sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"),
        WhisperModel(id: "small-q5_1", bytes: 190085487,
                     sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
        WhisperModel(id: "small-q8_0", bytes: 264464607,
                     sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"),
        WhisperModel(id: "small", bytes: 487601967,
                     sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        WhisperModel(id: "medium.en-q5_0", bytes: 539225533,
                     sha256: "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0"),
        WhisperModel(id: "medium.en-q8_0", bytes: 823382461,
                     sha256: "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c"),
        WhisperModel(id: "medium.en", bytes: 1533774781,
                     sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"),
        WhisperModel(id: "medium-q5_0", bytes: 539212467,
                     sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"),
        WhisperModel(id: "medium-q8_0", bytes: 823369779,
                     sha256: "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502"),
        WhisperModel(id: "medium", bytes: 1533763059,
                     sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        WhisperModel(id: "large-v3-turbo-q5_0", bytes: 574041195,
                     sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        WhisperModel(id: "large-v3-turbo-q8_0", bytes: 874188075,
                     sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
        WhisperModel(id: "large-v3-turbo", bytes: 1624555275,
                     sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        WhisperModel(id: "large-v3-q5_0", bytes: 1081140203,
                     sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
    ]

    static func model(id: String) -> WhisperModel? {
        models.first { $0.id == id }
    }

    /// The catalog model whose filename is the last component of `path`.
    static func model(forFile path: String) -> WhisperModel? {
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return models.first { $0.filename == name }
    }

    /// The default model for this Mac: the English-only model of the tier
    /// below, or its multilingual sibling when `language` isn't English.
    /// Quantized throughout — near-identical accuracy for half the RAM and a
    /// faster load. Mirrored by `scripts/model_catalog.sh`.
    ///
    /// | Chip          | RAM (whole GiB) | Model            | File   |
    /// |---------------|-----------------|------------------|--------|
    /// | Apple Silicon | < 8             | base.en-q5_1     |  60 MB |
    /// | Apple Silicon | 8 – 15          | small.en-q5_1    | 190 MB |
    /// | Apple Silicon | 16 – 31         | medium.en-q5_0   | 539 MB |
    /// | Apple Silicon | ≥ 32            | medium.en-q8_0   | 823 MB |
    /// | Intel (CPU)   | < 8             | tiny.en-q5_1     |  32 MB |
    /// | Intel (CPU)   | 8 – 15          | base.en-q5_1     |  60 MB |
    /// | Intel (CPU)   | ≥ 16            | small.en-q5_1    | 190 MB |
    static func recommended(for hardware: HardwareProfile, language: String = "en") -> WhisperModel {
        let id = recommendedID(isAppleSilicon: hardware.isAppleSilicon, memoryGiB: hardware.memoryGiB)
        let wanted = isEnglish(language) ? id : id.replacingOccurrences(of: ".en", with: "")
        // Every table entry is in the catalog (pinned by tests).
        return model(id: wanted) ?? model(id: id)!
    }

    private static func recommendedID(isAppleSilicon: Bool, memoryGiB gib: Int) -> String {
        if isAppleSilicon {
            switch gib {
            case ..<8: return "base.en-q5_1"
            case ..<16: return "small.en-q5_1"
            case ..<32: return "medium.en-q5_0"
            default: return "medium.en-q8_0"
            }
        }
        switch gib {
        case ..<8: return "tiny.en-q5_1"
        case ..<16: return "base.en-q5_1"
        default: return "small.en-q5_1"
        }
    }

    static func isEnglish(_ language: String) -> Bool {
        language.lowercased() == "en"
    }

    /// The one English-only rule, for a model id, file name or path: whisper's
    /// `.en` models (`small.en`, `small.en-q5_1`, `ggml-small.en.bin`).
    static func isEnglishOnly(_ idOrPath: String) -> Bool {
        let name = URL(fileURLWithPath: idOrPath).lastPathComponent
        return name.hasSuffix(".en") || name.contains(".en.") || name.contains(".en-")
    }
}
