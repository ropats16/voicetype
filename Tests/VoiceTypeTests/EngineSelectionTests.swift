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

    func testAnOlderConfigRunsWhisperAsBefore() throws {
        let config = try decode(#"{"model": "small.en-q5_1"}"#)
        XCTAssertEqual(config.engine, "whisper")
        XCTAssertEqual(config.engineModels, [:])
        XCTAssertEqual(config.modelChoice(for: .whisper), .named("small.en-q5_1"))
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
        let selected = select(.defaults, on: EngineEnvironment(macOSMajor: 15, macOSMinor: 0, hardware: hardware),
                              present: ["ggml-tiny.en.bin"])
        XCTAssertEqual(selected.spec, ModelSelection.resolve(.defaults, hardware: hardware, modelsDir: modelsDir,
                                                             presentFilenames: ["ggml-tiny.en.bin"]))
        XCTAssertEqual(selected.spec, .file("/models/ggml-tiny.en.bin"))
        XCTAssertNil(selected.fallbackReason)
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

    func testARunnableEngineIsNoIssue() {
        var config = Config.defaults
        config.engine = "parakeet"
        XCTAssertEqual(ConfigValidator.validate(config, engines: engines, environment: .mac(15)), [])
    }
}
