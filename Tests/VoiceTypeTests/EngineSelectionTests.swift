import XCTest
@testable import VoiceType

/// The engine settings in `config.json` (`engine`, `engineModels`), how they
/// resolve to the `ModelSpec` the app loads, and the warning a bad `engine`
/// gets — with a fake second engine registered beside whisper.
final class EngineSelectionTests: XCTestCase {

    private let engines = EngineRegistry([WhisperEngine(), FakeEngine()])
    private let modelsDir = URL(fileURLWithPath: "/models")

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func select(_ config: Config, on environment: EngineEnvironment = .mac(15),
                        present: Set<String> = []) -> ModelSelection.Selected {
        ModelSelection.select(config, environment: environment, engines: engines, modelsDir: modelsDir,
                              presentFilenames: present)
    }

    // MARK: - Config

    func testAConfigWithoutAnEngineIsAutomatic() throws {
        let config = try decode(#"{"model": "small.en-q5_1"}"#)
        XCTAssertEqual(config.engine, "auto")
        XCTAssertEqual(config.engineChoice, .automatic)
        XCTAssertEqual(Config.defaults.engineChoice, .automatic)
        XCTAssertEqual(config.engineModels, [:])
        XCTAssertEqual(config.modelChoice(for: .whisper), .named("small.en-q5_1"))
    }

    func testAnExplicitEngineIsKept() throws {
        XCTAssertEqual(try decode(#"{"engine": "parakeet"}"#).engineChoice, .engine(.parakeet))
        XCTAssertEqual(try decode(#"{"engine": "whisper"}"#).engineChoice, .engine(.whisper))
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(try decode(#"{"engine": "parakeet"}"#)))
        XCTAssertEqual(back.engine, "parakeet")
        XCTAssertEqual(try decode(#"{"engine": "future-engine"}"#).engineChoice, nil, "Unknown: not a choice")
    }

    func testEngineKeysAreReadAndRoundTrip() throws {
        let config = try decode(#"{"engine": "parakeet", "engineModels": {"parakeet": "big", "whisperkit": "auto"}}"#)
        XCTAssertEqual(config.engine, "parakeet")
        XCTAssertEqual(config.modelChoice(for: .parakeet), .named("big"))
        XCTAssertEqual(config.modelChoice(for: .whisperKit), .automatic)
        XCTAssertEqual(config.modelChoice(for: .appleSpeech), .automatic, "Unset means Automatic")

        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.engine, "parakeet")
        XCTAssertEqual(back.engineModels, config.engineModels)
    }

    func testAnUnknownEngineSurvivesARoundTrip() throws {
        let config = try decode(#"{"engine": "future-engine"}"#)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.engine, "future-engine", "Never rewritten: a newer build may know it")
    }

    func testWhisperModelChoiceStaysInTheModelKey() {
        var config = Config.defaults
        config.modelPath = "/m/custom.bin"
        config.setModelChoice(.named("tiny.en"), for: .whisper)
        XCTAssertEqual(config.model, .named("tiny.en"))
        XCTAssertEqual(config.modelPath, "", "A pick replaces a hand-set file")
        XCTAssertEqual(config.engineModels, [:])

        config.setModelChoice(.named("big"), for: .parakeet)
        XCTAssertEqual(config.engineModels, ["parakeet": .named("big")])
        XCTAssertEqual(config.model, .named("tiny.en"))
    }

    // MARK: - Selection

    func testTheConfiguredEngineResolvesItsOwnModel() {
        var config = Config.defaults
        config.engine = "parakeet"
        config.setModelChoice(.named("big"), for: .parakeet)

        let selected = select(config)

        XCTAssertEqual(selected.spec, ModelSpec(path: "/models/fake-big", sha256: nil, language: "en", engine: .parakeet))
        XCTAssertNil(selected.fallbackReason)
    }

    func testAnEngineThatCantRunFallsBackToTheWhisperModel() {
        var config = Config.defaults
        config.engine = "parakeet"
        config.language = "ja"
        config.model = .named("small-q5_1")

        let selected = select(config)

        XCTAssertEqual(selected.spec, .file("/models/ggml-small-q5_1.bin", language: "ja"))
        XCTAssertEqual(selected.fallbackReason, "Turbo (English/EU) doesn't support Japanese")
        XCTAssertEqual(selected.note, "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support Japanese.")
    }

    func testWhisperSelectionIsTheOldResolve() {
        let hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: 8 << 30)
        var config = Config.defaults
        config.engine = "whisper"
        let selected = select(config, on: EngineEnvironment(macOSMajor: 15, macOSMinor: 0, hardware: hardware),
                              present: ["ggml-tiny.en.bin"])
        XCTAssertEqual(selected.spec, ModelSelection.resolve(config, hardware: hardware, modelsDir: modelsDir,
                                                             presentFilenames: ["ggml-tiny.en.bin"]))
        XCTAssertEqual(selected.spec, .file("/models/ggml-tiny.en.bin"))
        XCTAssertNil(selected.fallbackReason)
    }

    // MARK: - Automatic (`EnginePolicy`)

    /// Turbo (fake parakeet) and Apple Speech (fake, macOS 26) beside whisper;
    /// which models are installed comes from `EngineFacts`.
    private let autoEngines = EngineRegistry([
        WhisperEngine(),
        FakeEngine(kind: .parakeet),
        FakeEngine(kind: .appleSpeech, minimumMacOS: 26, supportedLanguages: ["en", "ja"]),
    ])

    private func selectAuto(_ config: Config = .defaults, on environment: EngineEnvironment = .mac(26, gib: 8),
                            installed: Set<EngineKind>, failed: Set<EngineKind> = []) -> ModelSelection.Selected {
        let facts = EngineFacts(isPresent: { installed.contains($0.engine) }, failed: failed)
        return ModelSelection.select(config, environment: environment, engines: autoEngines, modelsDir: modelsDir,
                                     presentFilenames: ["ggml-small.en-q5_1.bin"], facts: facts)
    }

    func testAutomaticRunsTurboWithItsOwnModelPick() {
        var config = Config.defaults
        config.setModelChoice(.named("big"), for: .parakeet)

        let selected = selectAuto(config, installed: [.parakeet, .appleSpeech])

        XCTAssertEqual(selected.spec, ModelSpec(path: "/models/fake-big", sha256: nil, language: "en", engine: .parakeet))
        XCTAssertTrue(selected.isAutomatic)
        XCTAssertNil(selected.fallbackReason)
        XCTAssertNil(selected.note)
    }

    func testAutomaticWithoutTurboRunsAppleSpeechThenWhisper() {
        let apple = selectAuto(installed: [.appleSpeech])
        XCTAssertEqual(apple.spec.engine, .appleSpeech)
        XCTAssertEqual(apple.fallbackReason, "Turbo isn't downloaded")
        XCTAssertEqual(apple.note, "Using Apple Speech because Turbo isn't downloaded.")

        let whisper = selectAuto(installed: [])
        XCTAssertEqual(whisper.spec, .file("/models/ggml-small.en-q5_1.bin"), "whisper's RAM-tier Automatic (8 GB)")
        XCTAssertEqual(whisper.note, "Using Whisper (whisper.cpp) because Turbo isn't downloaded.")
    }

    func testAutomaticSkipsAnEngineThatFailedToLoad() {
        let selected = selectAuto(installed: [.parakeet], failed: [.parakeet])
        XCTAssertEqual(selected.spec.engine, .whisper)
        XCTAssertEqual(selected.fallbackReason, "Turbo failed to load")
    }

    func testAutomaticUnderAutoDetectRunsWhisper() {
        var config = Config.defaults
        config.language = ModelSpec.autoDetect
        let selected = selectAuto(config, installed: [.parakeet, .appleSpeech])
        XCTAssertEqual(selected.spec.engine, .whisper)
        XCTAssertEqual(selected.fallbackReason, "Turbo doesn't detect the language")
    }

    func testAutomaticNeverRunsAnEngineWhoseModelIsMissing() {
        // The fakes report presence by path; nothing installed → whisper, never a download.
        let missing = EngineRegistry([WhisperEngine(), FakeEngine(kind: .parakeet, present: [])])
        let selected = ModelSelection.select(.defaults, environment: .mac(26), engines: missing,
                                             modelsDir: modelsDir, presentFilenames: [])
        XCTAssertEqual(selected.spec.engine, .whisper)
    }

    // MARK: - Validation

    func testAnEngineThatCantRunIsAWarningNamingTheFallback() {
        for (id, reason) in [("nonsense", "\"nonsense\" isn't a known engine"),
                             ("whisperkit", "WhisperKit (Core ML) isn't in this build")] {
            var config = Config.defaults
            config.engine = id
            let issues = ConfigValidator.validate(config, engines: engines, environment: .mac(15))
            XCTAssertEqual(issues, [ConfigIssue(severity: .warning,
                                                message: "`engine` \"\(id)\": \(reason); using Whisper (whisper.cpp).")])
        }
    }

    func testAutomaticIsNoIssue() {
        XCTAssertEqual(ConfigValidator.validate(.defaults, engines: engines, environment: .mac(14, appleSilicon: false)), [])
    }

    func testARunnableEngineIsNoIssue() {
        var config = Config.defaults
        config.engine = "parakeet"
        XCTAssertEqual(ConfigValidator.validate(config, engines: engines, environment: .mac(15)), [])
    }
}
