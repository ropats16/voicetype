import XCTest
@testable import VoiceType

/// Tests for the engine's model catalog, its hardware auto-pick table, and the
/// config → model resolution. Pure: hardware and present files are injected.
final class ModelCatalogTests: XCTestCase {

    private func appleSilicon(_ gib: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: true, memoryBytes: gib << 30)
    }

    private func intel(_ gib: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: false, memoryBytes: gib << 30)
    }

    // MARK: - Catalog

    func testCatalogHasEnglishMultilingualAndQuantizedVariants() {
        let ids = Set(ModelCatalog.models.map(\.id))
        for id in ["tiny.en", "base.en", "small.en", "medium.en",                 // English
                   "tiny", "base", "small", "medium", "large-v3-turbo",          // multilingual
                   "small.en-q5_1", "small.en-q8_0", "medium.en-q5_0", "large-v3-turbo-q5_0"] {
            XCTAssertTrue(ids.contains(id), "catalog is missing \(id)")
        }
        XCTAssertEqual(ids.count, ModelCatalog.models.count, "ids are unique")
    }

    func testEveryModelPinsASHA256AndSize() {
        for model in ModelCatalog.models {
            XCTAssertEqual(model.sha256.count, 64, "\(model.id): sha256 is 64 hex chars")
            XCTAssertTrue(model.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(model.id): lowercase hex")
            XCTAssertGreaterThan(model.bytes, 10_000_000, "\(model.id): size is pinned")
        }
    }

    func testFilenameAndLanguageTraitsFollowTheId() throws {
        let q = try XCTUnwrap(ModelCatalog.model(id: "small.en-q5_1"))
        XCTAssertEqual(q.filename, "ggml-small.en-q5_1.bin")
        XCTAssertTrue(q.isEnglishOnly)
        XCTAssertEqual(q.quantization, "q5_1")

        let m = try XCTUnwrap(ModelCatalog.model(id: "medium"))
        XCTAssertFalse(m.isEnglishOnly)
        XCTAssertNil(m.quantization)
    }

    func testModelForFileMatchesByFilename() {
        XCTAssertEqual(ModelCatalog.model(forFile: "/any/dir/ggml-medium.en.bin")?.id, "medium.en")
        XCTAssertNil(ModelCatalog.model(forFile: "/any/dir/my-finetune.bin"))
        XCTAssertNil(ModelCatalog.model(forFile: ""))
    }

    // MARK: - Auto-pick table

    func testAppleSiliconAutoPickByRAM() {
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(4)).id, "base.en-q5_1")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(8)).id, "small.en-q5_1",
                       "M1 8 GB gets a light quantized model, not medium.en")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(16)).id, "medium.en-q5_0")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(24)).id, "medium.en-q5_0")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(32)).id, "medium.en-q8_0")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(128)).id, "medium.en-q8_0")
    }

    func testIntelAutoPickByRAM() {
        XCTAssertEqual(ModelCatalog.recommended(for: intel(4)).id, "tiny.en-q5_1")
        XCTAssertEqual(ModelCatalog.recommended(for: intel(8)).id, "base.en-q5_1")
        XCTAssertEqual(ModelCatalog.recommended(for: intel(16)).id, "small.en-q5_1")
        XCTAssertEqual(ModelCatalog.recommended(for: intel(64)).id, "small.en-q5_1")
    }

    func testNonEnglishLanguagePicksTheMultilingualSibling() {
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(8), language: "de").id, "small-q5_1")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(16), language: "auto").id, "medium-q5_0")
        XCTAssertEqual(ModelCatalog.recommended(for: appleSilicon(16), language: "en").id, "medium.en-q5_0")
    }

    func testEveryAutoPickIsInTheCatalog() {
        for gib: UInt64 in [1, 4, 7, 8, 12, 15, 16, 18, 24, 31, 32, 36, 48, 64, 96, 128, 192] {
            for hw in [appleSilicon(gib), intel(gib)] {
                for lang in ["en", "fr"] {
                    XCTAssertNotNil(ModelCatalog.model(id: ModelCatalog.recommended(for: hw, language: lang).id))
                }
            }
        }
    }

    // MARK: - Resolution (config → what the engine loads)

    private let dir = URL(fileURLWithPath: "/models")

    private func resolve(model: ModelChoice = .automatic, modelPath: String = "",
                         language: String = "en", hardware: HardwareProfile? = nil,
                         present: Set<String> = []) -> ModelSpec {
        ModelSelection.resolve(model: model, modelPath: modelPath, language: language,
                               hardware: hardware ?? appleSilicon(8), modelsDir: dir,
                               presentFilenames: present)
    }

    func testAutoUsesTheRecommendedModelWithItsChecksum() {
        let spec = resolve(present: ["ggml-small.en-q5_1.bin"])
        XCTAssertEqual(spec.path, "/models/ggml-small.en-q5_1.bin")
        XCTAssertEqual(spec.sha256, ModelCatalog.model(id: "small.en-q5_1")?.sha256)
        XCTAssertEqual(spec.language, "en")
    }

    func testAutoFallsBackToTheLargestPresentModelThatFits() {
        // Recommended small.en-q5_1 (190 MB) isn't downloaded: use the biggest
        // present model no larger than it, rather than reporting "missing".
        let spec = resolve(present: ["ggml-tiny.en.bin", "ggml-base.en.bin", "ggml-medium.en.bin", "notes.txt"])
        XCTAssertEqual(spec.path, "/models/ggml-base.en.bin")
    }

    func testAutoFallsBackToTheSmallestPresentModelWhenNoneFit() {
        let spec = resolve(present: ["ggml-medium.en.bin", "ggml-large-v3-turbo.bin"])
        XCTAssertEqual(spec.path, "/models/ggml-medium.en.bin")
    }

    func testAutoWithNothingPresentPointsAtTheRecommendedModel() {
        XCTAssertEqual(resolve().path, "/models/ggml-small.en-q5_1.bin",
                       "Reported missing, with the model to download")
    }

    func testAutoForANonEnglishLanguageSkipsEnglishOnlyFallbacks() {
        let spec = resolve(language: "fr", present: ["ggml-base.en.bin", "ggml-tiny.bin"])
        XCTAssertEqual(spec.path, "/models/ggml-tiny.bin")
        XCTAssertEqual(spec.language, "fr")
    }

    func testExplicitModelWinsOverAutoPickEvenWhenMissing() {
        let spec = resolve(model: .named("medium.en"), present: ["ggml-small.en-q5_1.bin"])
        XCTAssertEqual(spec.path, "/models/ggml-medium.en.bin")
        XCTAssertEqual(spec.sha256, ModelCatalog.model(id: "medium.en")?.sha256)
    }

    func testExplicitModelPathWinsOverEverything() {
        // An existing config's `modelPath` keeps working, and a catalog file is
        // still verified against its pinned checksum.
        let spec = resolve(model: .named("small.en"), modelPath: "/old/ggml-medium.en.bin")
        XCTAssertEqual(spec.path, "/old/ggml-medium.en.bin")
        XCTAssertEqual(spec.sha256, ModelCatalog.model(id: "medium.en")?.sha256)
    }

    func testCustomModelPathIsUsedUnverified() {
        let spec = resolve(modelPath: "/x/finetune.bin", language: "de")
        XCTAssertEqual(spec.path, "/x/finetune.bin")
        XCTAssertNil(spec.sha256)
        XCTAssertEqual(spec.language, "de")
    }

    func testTildeInModelPathExpands() {
        let spec = resolve(modelPath: "~/m/ggml-tiny.en.bin")
        XCTAssertEqual(spec.path, NSHomeDirectory() + "/m/ggml-tiny.en.bin")
    }

    func testEnglishOnlyModelsForceEnglish() {
        XCTAssertEqual(resolve(model: .named("small.en"), language: "fr").language, "en")
        XCTAssertEqual(resolve(model: .named("small"), language: "fr").language, "fr")
        XCTAssertEqual(resolve(model: .named("small"), language: "").language, "auto", "blank language = auto-detect")
    }

    func testUnknownModelIdIsTreatedAsAnUnverifiedFileInTheModelsDir() {
        let spec = resolve(model: .named("large-v1"))
        XCTAssertEqual(spec.path, "/models/ggml-large-v1.bin")
        XCTAssertNil(spec.sha256)
    }

    // MARK: - Keep warm

    func testKeepWarmDefaultsOffOnlyOn8GBOrLess() {
        XCTAssertEqual(ModelSelection.idleUnloadAfter(keepWarm: nil, idleMinutes: 5, hardware: appleSilicon(8)), 300)
        XCTAssertNil(ModelSelection.idleUnloadAfter(keepWarm: nil, idleMinutes: 5, hardware: appleSilicon(16)))
    }

    func testExplicitKeepWarmWins() {
        XCTAssertNil(ModelSelection.idleUnloadAfter(keepWarm: true, idleMinutes: 5, hardware: appleSilicon(8)))
        XCTAssertEqual(ModelSelection.idleUnloadAfter(keepWarm: false, idleMinutes: 2, hardware: appleSilicon(64)), 120)
        XCTAssertEqual(ModelSelection.idleUnloadAfter(keepWarm: false, idleMinutes: 0, hardware: appleSilicon(64)), 60,
                       "a non-positive idle time is clamped to 1 min")
    }

    // MARK: - Shared rules

    func testOneEnglishOnlyRuleForIdsFilesAndPaths() {
        for name in ["small.en", "small.en-q5_1", "ggml-small.en.bin", "/m/ggml-medium.en-q5_0.bin"] {
            XCTAssertTrue(ModelCatalog.isEnglishOnly(name), name)
        }
        for name in ["small", "small-q5_1", "ggml-large-v3-turbo.bin", "/m/finetune.bin", "/m/encoder.bin"] {
            XCTAssertFalse(ModelCatalog.isEnglishOnly(name), name)
        }
    }

    func testModelChoiceIsStoredAsAutoOrTheId() throws {
        let encoded = try JSONEncoder().encode([ModelChoice.automatic, .named("small.en-q5_1")])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["auto","small.en-q5_1"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ModelChoice].self, from: Data(#"["auto","","base"]"#.utf8)),
                       [.automatic, .automatic, .named("base")])
    }

    // MARK: - Download hint

    func testDownloadCommandOnlyForCatalogModelsInTheModelsFolder() {
        let catalog = ModelSpec.file("/models/ggml-small.en-q5_1.bin")
        XCTAssertEqual(ModelSelection.downloadCommand(for: catalog, modelsDir: dir), "make model MODEL=small.en-q5_1")
        XCTAssertNil(ModelSelection.downloadCommand(for: .file("/models/finetune.bin"), modelsDir: dir),
                     "A custom file has no download command")
        XCTAssertNil(ModelSelection.downloadCommand(for: .file("/old/ggml-medium.en.bin"), modelsDir: dir),
                     "make model wouldn't put it at a custom path")
        XCTAssertNil(ModelSelection.downloadCommand(for: resolve(model: .named("large-v1")), modelsDir: dir),
                     "A model the catalog doesn't pin can't be fetched by make model")
    }

    func testPartialDownloadsDontCountAsPresent() throws {
        let models = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: models) }
        FileManager.default.createFile(atPath: models.appendingPathComponent("ggml-tiny.en.bin").path, contents: Data())
        FileManager.default.createFile(atPath: models.appendingPathComponent("ggml-small.en.bin.part").path, contents: Data())

        XCTAssertEqual(ModelSelection.presentFilenames(in: models), ["ggml-tiny.en.bin"])
    }
}
