import XCTest
@testable import VoiceType

/// WhisperKit's `EngineDescriptor`: where its models resolve (and their pinned
/// manifest digests), when it's offered, and how a missing model is reported.
/// Pure, or on a temp dir.
final class WhisperKitEngineTests: XCTestCase {

    private let engine = WhisperKitEngine()
    private let modelsDir = URL(fileURLWithPath: "/tmp/vt/models")

    private func context(_ language: String = "en", modelsDir: URL? = nil, memoryGiB: UInt64 = 8) -> ModelContext {
        ModelContext(language: language, hardware: HardwareProfile(isAppleSilicon: true, memoryBytes: memoryGiB << 30),
                     modelsDir: modelsDir ?? self.modelsDir, presentFilenames: [])
    }

    private func automaticID(_ language: String, memoryGiB: UInt64) -> String {
        URL(fileURLWithPath: engine.resolve(.automatic, in: context(language, memoryGiB: memoryGiB)).path)
            .lastPathComponent
    }

    func testIsRegistered() {
        XCTAssertEqual(EngineRegistry.shared.descriptor(for: .whisperKit)?.kind, .whisperKit)
        XCTAssertEqual(engine.models.map(\.id), WhisperKitCatalog.models.map(\.id))
    }

    func testNamedResolvesToItsFolderWithThePinnedManifest() throws {
        let tiny = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        XCTAssertEqual(engine.resolve(.named("tiny.en"), in: context()),
                       ModelSpec(path: "/tmp/vt/models/whisperkit/tiny.en", sha256: tiny.manifestSHA256,
                                 language: "en", engine: .whisperKit))
        // A hand-edited id still resolves, unverified (and then reports missing).
        XCTAssertEqual(engine.resolve(.named("my-finetune"), in: context()),
                       ModelSpec(path: "/tmp/vt/models/whisperkit/my-finetune", sha256: nil,
                                 language: "en", engine: .whisperKit))
    }

    /// English gets the compressed small.en on every Mac; other languages
    /// and auto-detect a multilingual model sized to the RAM: small on an
    /// 8 GB Mac (first-class per the PRD), large-v3-turbo 626 MB above that.
    func testAutomaticFollowsLanguageAndRAM() {
        for memory: UInt64 in [8, 16, 64] {
            XCTAssertEqual(automaticID("en", memoryGiB: memory), "small.en_217MB", "\(memory) GB")
        }
        for language in ["de", ModelSpec.autoDetect] {
            XCTAssertEqual(automaticID(language, memoryGiB: 8), "small", language)
            XCTAssertEqual(automaticID(language, memoryGiB: 16), "large-v3-v20240930_626MB", language)
            XCTAssertEqual(automaticID(language, memoryGiB: 64), "large-v3-v20240930_626MB", language)
        }
    }

    func testOnlyOnAppleSilicon() {
        func env(_ appleSilicon: Bool) -> EngineEnvironment {
            EngineEnvironment(macOSMajor: 14, macOSMinor: 2,
                              hardware: HardwareProfile(isAppleSilicon: appleSilicon, memoryBytes: 16 << 30))
        }
        XCTAssertEqual(engine.availability(in: env(true)), .available)
        XCTAssertEqual(engine.availability(in: env(false)),
                       .unavailable(reason: "WhisperKit needs Apple Silicon"))
    }

    /// A catalog folder counts once its manifest is there (the download
    /// writes it last, then renames the folder into place); hashing is the
    /// load's job.
    func testACatalogFolderIsPresentOnlyWithItsManifest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = engine.resolve(.named("tiny.en"), in: context(modelsDir: dir))
        XCTAssertFalse(engine.isPresent(spec))

        try FileManager.default.createDirectory(atPath: spec.path, withIntermediateDirectories: true)
        XCTAssertFalse(engine.isPresent(spec), "an empty or partial folder is missing, not failed")

        try Data().write(to: URL(fileURLWithPath: spec.path).appendingPathComponent(ModelVerifier.folderManifestName))
        XCTAssertTrue(engine.isPresent(spec))
        XCTAssertEqual(engine.installedModelIDs(in: context(modelsDir: dir)), ["tiny.en"])
    }

    func testDownloadHintNamesTheModel() {
        let spec = engine.resolve(.named("base.en"), in: context())
        XCTAssertEqual(engine.downloadHint(for: spec), .inApp(command: "make whisperkit-model WHISPERKIT=base.en"))
        XCTAssertNil(engine.downloadHint(for: engine.resolve(.named("my-finetune"), in: context())))
    }

    func testModelArgumentIsVerifiedWhenItIsACatalogFolder() throws {
        let tiny = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        XCTAssertEqual(engine.spec(forModelArgument: "/x/whisperkit/tiny.en", language: "en"),
                       ModelSpec(path: "/x/whisperkit/tiny.en", sha256: tiny.manifestSHA256, language: "en",
                                 engine: .whisperKit))
        XCTAssertNil(engine.spec(forModelArgument: "/x/custom", language: "").sha256)
        XCTAssertEqual(engine.spec(forModelArgument: "/x/custom", language: "").language, ModelSpec.autoDetect)
    }
}
