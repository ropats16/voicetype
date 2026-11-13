import XCTest
@testable import VoiceType

/// Parakeet's `EngineDescriptor`: where its models resolve, when it's offered,
/// and how a missing model is reported. Pure, or on a temp dir.
final class ParakeetEngineTests: XCTestCase {

    private let engine = ParakeetEngine()
    private let modelsDir = URL(fileURLWithPath: "/tmp/vt/models")

    private func context(_ language: String = "en", modelsDir: URL? = nil) -> ModelContext {
        ModelContext(language: language, hardware: HardwareProfile(isAppleSilicon: true, memoryBytes: 8 << 30),
                     modelsDir: modelsDir ?? self.modelsDir, presentFilenames: [])
    }

    func testIsRegisteredAsTurbo() {
        XCTAssertEqual(EngineRegistry.shared.descriptor(for: .parakeet)?.kind, .parakeet)
        XCTAssertEqual(engine.kind.displayName, "Turbo (English/EU)")
    }

    func testAutomaticAndNamedResolveToTheCatalogFolder() {
        let expected = ModelSpec(path: "/tmp/vt/models/parakeet/parakeet-tdt-0.6b-v3", sha256: nil,
                                 language: "de", engine: .parakeet)
        XCTAssertEqual(engine.resolve(.automatic, in: context("de")), expected)
        XCTAssertEqual(engine.resolve(.named("parakeet-tdt-0.6b-v3"), in: context("de")), expected)
        // A hand-edited id still resolves (and then reports missing).
        XCTAssertEqual(engine.resolve(.named("parakeet-x"), in: context()).path, "/tmp/vt/models/parakeet/parakeet-x")
        XCTAssertEqual(engine.models.map(\.id), ["parakeet-tdt-0.6b-v3"])
    }

    func testOnlyOnAppleSilicon() {
        func env(_ appleSilicon: Bool) -> EngineEnvironment {
            EngineEnvironment(macOSMajor: 14, macOSMinor: 2,
                              hardware: HardwareProfile(isAppleSilicon: appleSilicon, memoryBytes: 16 << 30))
        }
        XCTAssertEqual(engine.availability(in: env(true)), .available)
        XCTAssertEqual(engine.availability(in: env(false)), .unavailable(reason: "Turbo needs Apple Silicon"))
    }

    /// Shown for its 25 languages and auto-detect; whisper takes the rest.
    func testShownOnlyForSupportedLanguages() {
        let appleSilicon = EngineEnvironment(macOSMajor: 15, macOSMinor: 0,
                                             hardware: HardwareProfile(isAppleSilicon: true, memoryBytes: 16 << 30))
        let registry = EngineRegistry([WhisperEngine(), ParakeetEngine()])
        XCTAssertEqual(engine.supportedLanguages?.count, 26)
        for code in ["en", "de", "uk", ModelSpec.autoDetect] {
            XCTAssertTrue(registry.available(in: appleSilicon, language: code).contains(.parakeet), code)
        }
        for code in ["ja", "zh", "ar"] {
            XCTAssertFalse(registry.available(in: appleSilicon, language: code).contains(.parakeet), code)
            XCTAssertEqual(registry.select(engineID: "parakeet", language: code, in: appleSilicon).kind, .whisper)
        }
    }

    func testDownloadHintAndCommandLineModel() {
        let spec = engine.resolve(.automatic, in: context())
        XCTAssertEqual(engine.downloadHint(for: spec), .command("make parakeet-model"))
        XCTAssertEqual(engine.spec(forModelArgument: "/x/my-parakeet", language: "fr"),
                       ModelSpec(path: "/x/my-parakeet", sha256: nil, language: "fr", engine: .parakeet))
        XCTAssertEqual(engine.spec(forModelArgument: "/x/y", language: "").language, ModelSpec.autoDetect)
    }

    /// A catalog folder missing a file is missing (so the user gets the
    /// download hint), not a failed load; a custom folder only has to exist.
    func testPresenceChecksEveryCatalogFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let spec = engine.resolve(.automatic, in: context(modelsDir: dir))
        XCTAssertFalse(engine.isPresent(spec))

        let folder = URL(fileURLWithPath: spec.path)
        for file in ParakeetCatalog.defaultModel.files.dropLast() {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertFalse(engine.isPresent(spec), "one file short")
        let last = folder.appendingPathComponent(ParakeetCatalog.defaultModel.files.last!.path)
        try FileManager.default.createDirectory(at: last.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: last)
        XCTAssertTrue(engine.isPresent(spec), "presence only; checksums are the load's job")
        XCTAssertEqual(engine.installedModelIDs(in: context(modelsDir: dir)), ["parakeet-tdt-0.6b-v3"])

        let custom = dir.appendingPathComponent("my-parakeet")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        XCTAssertTrue(engine.isPresent(engine.spec(forModelArgument: custom.path, language: "en")))
    }
}
