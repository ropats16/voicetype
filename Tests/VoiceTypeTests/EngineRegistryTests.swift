import XCTest
@testable import VoiceType

/// A second engine registered beside whisper, the way an adapter plugs in:
/// one `EngineDescriptor`. Its adapter echoes its own name, so a test can
/// tell which engine ran a job. Shared by the registry, selection, settings
/// and bench tests.
struct FakeEngine: EngineDescriptor {
    var kind: EngineKind = .parakeet
    var minimumMacOS = 0
    var needsAppleSilicon = false
    var supportedLanguages: Set<String>? = ["en", "de"]
    /// What `isPresent` says, by `ModelSpec.path`; nil = present.
    var present: Set<String>?
    var models = [EngineModelOption(id: "fast", label: "Fast"), EngineModelOption(id: "big", label: "Big")]
    var acknowledgement = "Fake engine, for tests."

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        if needsAppleSilicon && !environment.hardware.isAppleSilicon {
            return .unavailable(reason: "\(kind.displayName) needs Apple Silicon")
        }
        return environment.isAtLeast(macOS: minimumMacOS) ? .available
            : .unavailable(reason: "\(kind.displayName) needs macOS \(minimumMacOS)")
    }

    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        let id: String
        switch choice {
        case .automatic: id = "fast"
        case .named(let named): id = named
        }
        return ModelSpec(path: context.modelsDir.appendingPathComponent("fake-\(id)").path, sha256: nil,
                         language: context.language, engine: kind)
    }

    func isPresent(_ spec: ModelSpec) -> Bool { present.map { $0.contains(spec.path) } ?? true }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        .instructions("Open Settings › Model to download it.")
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        { [kind] spec in EchoAdapter(name: "\(kind.rawValue):\(URL(fileURLWithPath: spec.path).lastPathComponent)") }
    }
}

/// Answers every job with its own name.
final class EchoAdapter: TranscriptionAdapter {
    let name: String
    init(name: String) { self.name = name }
    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        [Transcript.Segment(text: name, start: 0, end: 1)]
    }
}

extension EngineEnvironment {
    static func mac(_ major: Int, appleSilicon: Bool = true, gib: UInt64 = 16) -> EngineEnvironment {
        EngineEnvironment(macOSMajor: major, macOSMinor: 0,
                          hardware: HardwareProfile(isAppleSilicon: appleSilicon, memoryBytes: gib << 30))
    }
}

/// The engine-selection seam: which engines a Mac can run, how the
/// configured one falls back to whisper, and a live switch between engines
/// through the real `TranscriptionEngine`.
@MainActor
final class EngineRegistryTests: XCTestCase {

    private let registry = EngineRegistry([WhisperEngine(), FakeEngine()])

    // MARK: - Registry

    func testTheAppRegistryAlwaysHasWhisper() {
        XCTAssertEqual(EngineRegistry.shared.descriptor(for: .whisper)?.kind, .whisper)
        XCTAssertTrue(EngineRegistry.shared.available(in: .mac(14, appleSilicon: false), language: "ja").contains(.whisper))
    }

    func testEngineIDsAreTheBenchIDs() {
        XCTAssertEqual(EngineKind.allCases.map(\.rawValue), ["whisper", "whisperkit", "parakeet", "apple-speech"])
        XCTAssertEqual(EngineKind.parakeet.displayName, "Turbo (English/EU)")
    }

    func testAvailableEnginesFollowOSHardwareAndLanguage() {
        let gated = EngineRegistry([WhisperEngine(), FakeEngine(kind: .appleSpeech, minimumMacOS: 26, supportedLanguages: nil),
                                    FakeEngine(kind: .parakeet, needsAppleSilicon: true)])
        XCTAssertEqual(gated.available(in: .mac(26), language: "en"), [.whisper, .appleSpeech, .parakeet])
        XCTAssertEqual(gated.available(in: .mac(15), language: "en"), [.whisper, .parakeet])
        XCTAssertEqual(gated.available(in: .mac(26), language: "ja"), [.whisper, .appleSpeech],
                       "Parakeet is hidden for a language it doesn't support")
        XCTAssertEqual(gated.available(in: .mac(26, appleSilicon: false), language: "en"), [.whisper, .appleSpeech])
    }

    // MARK: - Selection

    func testTheConfiguredEngineIsUsedWhenItCan() {
        XCTAssertEqual(registry.select(engineID: "parakeet", language: "de", in: .mac(15)),
                       EngineSelection(kind: .parakeet, fallbackReason: nil))
    }

    func testEverythingElseFallsBackToWhisperSayingWhy() {
        let gated = EngineRegistry([WhisperEngine(), FakeEngine(kind: .appleSpeech, minimumMacOS: 26)])
        let cases: [(String, String, String)] = [
            ("apple-speech", "en", "Apple Speech needs macOS 26"),
            ("parakeet", "en", "Turbo (English/EU) isn't in this build"),
            ("nonsense", "en", "\"nonsense\" isn't a known engine"),
        ]
        for (id, language, reason) in cases {
            XCTAssertEqual(gated.select(engineID: id, language: language, in: .mac(15)),
                           EngineSelection(kind: .whisper, fallbackReason: reason), id)
        }
        XCTAssertEqual(registry.select(engineID: "parakeet", language: "ja", in: .mac(15)).fallbackReason,
                       "Turbo (English/EU) doesn't support Japanese")
        XCTAssertEqual(registry.select(engineID: "parakeet", language: "auto", in: .mac(15)).fallbackReason,
                       "Turbo (English/EU) doesn't support auto-detect")
    }

    func testWhisperNeverFallsBack() {
        XCTAssertEqual(registry.select(engineID: "whisper", language: "ja", in: .mac(14, appleSilicon: false)),
                       EngineSelection(kind: .whisper, fallbackReason: nil))
    }

    // MARK: - Presence and hints

    func testPresenceAndHintsComeFromTheSpecsEngine() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("model.mlmodelc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = ModelSpec(path: "/nowhere", sha256: nil, language: "en", engine: .parakeet)
        XCTAssertTrue(registry.isPresent(fake), "The fake engine says its models are present wherever they are")
        XCTAssertTrue(registry.isPresent(ModelSpec(path: dir.appendingPathComponent("model.mlmodelc").path,
                                                   sha256: nil, language: "en", engine: .whisper)),
                      "By default a directory counts as a present model")
        XCTAssertFalse(registry.isPresent(.file("/nowhere/ggml-tiny.en.bin")))
        XCTAssertFalse(registry.isPresent(ModelSpec(path: "/x", sha256: nil, language: "en", engine: .whisperKit)),
                       "An engine this build lacks has no models")

        XCTAssertEqual(registry.downloadHint(for: fake), .instructions("Open Settings › Model to download it."))
        let catalog = ModelSpec.file(Paths.modelsDir.appendingPathComponent("ggml-tiny.en.bin").path)
        XCTAssertEqual(registry.downloadHint(for: catalog), .command("make model MODEL=tiny.en"))
    }

    // MARK: - Switching engines live

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSwitchingEngineIsAModelSwitch() async throws {
        let fakeWhisper = FakeEngine(kind: .whisper, supportedLanguages: nil)
        let engines = EngineRegistry([fakeWhisper, FakeEngine()])
        let engine = TranscriptionEngine.registered(
            model: ModelSpec(path: "/m/a.bin", sha256: nil, language: "en", engine: .whisper),
            options: EngineOptions(), engines: engines)
        engine.load()
        let before = try await engine.transcribe([0.1]).text
        XCTAssertEqual(before, "whisper:a.bin")

        let turbo = ModelSpec(path: "/m/fake-fast", sha256: nil, language: "en", engine: .parakeet)
        engine.switchModel(to: turbo)
        let after = try await engine.transcribe([0.1]).text

        XCTAssertEqual(after, "parakeet:fake-fast")
        XCTAssertEqual(engine.model, turbo)
        XCTAssertEqual(engine.status, .ready)
    }

    func testAMissingModelOnTheNewEngineKeepsTheOldOne() async throws {
        let fakeWhisper = FakeEngine(kind: .whisper, supportedLanguages: nil)
        let engines = EngineRegistry([fakeWhisper, FakeEngine(present: [])])
        let whisper = ModelSpec(path: "/m/a.bin", sha256: nil, language: "en", engine: .whisper)
        let engine = TranscriptionEngine.registered(model: whisper, options: EngineOptions(), engines: engines)
        var seen: [TranscriptionStatus] = []
        engine.onStatusChange = { seen.append($0) }
        engine.load()
        _ = try await engine.transcribe([0.1])

        engine.switchModel(to: ModelSpec(path: "/m/fake-big", sha256: nil, language: "en", engine: .parakeet))
        _ = try await engine.transcribe([0.1])
        await waitUntil("settled") { seen.last == .ready && seen.count > 2 }

        XCTAssertTrue(seen.contains(.failed(reason: "Couldn't switch to Turbo (English/EU) fake-big (model not found). "
                                            + "Still using a.bin.")), "\(seen)")
        XCTAssertEqual(engine.model, whisper)
    }
}
