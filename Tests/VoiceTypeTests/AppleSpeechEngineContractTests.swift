import XCTest
@testable import VoiceType

/// Contract test for Apple's SpeechAnalyzer engine (#14), through the app's
/// registry (`EngineContract`), plus what's particular to it. Skipped below
/// macOS 26 and when the en-US speech model isn't on this Mac (Settings ›
/// Model › Download, or the opt-in install test below).
final class AppleSpeechEngineContractTests: XCTestCase {

    private let spec = ModelSpec.appleSpeech(language: "en-US")

    private func skipUnlessAvailable() throws {
        guard #available(macOS 26, *), AppleSpeechAvailability.isAvailable() else {
            throw XCTSkip("Apple SpeechAnalyzer needs macOS 26")
        }
    }

    func testTranscribesJFK() async throws {
        try skipUnlessAvailable()
        try await EngineContract.assertTranscribesJFK(spec)
    }

    func testSilenceYieldsNoText() async throws {
        try skipUnlessAvailable()
        let text = try await EngineContract.assertSilenceYieldsNoTags(spec)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespaces), "")
    }

    /// "auto" can't detect: it transcribes in the Mac's language, which here
    /// must be one the transcriber has (any English does for this clip).
    func testAutoLanguageTranscribes() async throws {
        try skipUnlessAvailable()
        try await EngineContract.assertTranscribesJFK(.appleSpeech(language: ModelSpec.autoDetect))
    }

    /// Fed as one buffer, the transcriber silently kept only the last ~2.5
    /// minutes of a long clip; every repeat of the quote must come back.
    func testTranscribesAllOfALongClip() async throws {
        let engine = try await loadedEngine()
        let jfk = try EngineContract.loadMono16k(EngineContract.jfkPath)
        let repeats = 30   // 5.5 minutes

        let transcript = try await engine.transcribe(Array([[Float]](repeating: jfk, count: repeats).joined()))

        let mentions = transcript.text.lowercased().components(separatedBy: "country").count - 1
        XCTAssertEqual(mentions, 2 * repeats, "Got \(transcript.text.count) characters")
        XCTAssertLessThan(transcript.segments.first?.start ?? .infinity, 1)
    }

    /// An unsupported language fails the load with a reason the user can act
    /// on, never a download.
    func testUnsupportedLanguageFailsTheLoad() throws {
        try skipUnlessAvailable()
        let make = TranscriptionEngine.appleSpeechAdapter()
        XCTAssertThrowsError(try make(.appleSpeech(language: "xx"))) {
            XCTAssertEqual($0 as? AppleSpeechError, .unsupportedLanguage("xx"))
        }
    }

    /// Opt-in (it may download hundreds of MB): installs the en-US model, so
    /// the tests above run. `VOICETYPE_INSTALL_APPLE_SPEECH=1 swift test
    /// --filter AppleSpeechEngineContractTests`.
    func testInstallLeavesTheModelInstalled() async throws {
        try skipUnlessAvailable()
        guard #available(macOS 26, *) else { return }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICETYPE_INSTALL_APPLE_SPEECH"] == "1",
                          "set VOICETYPE_INSTALL_APPLE_SPEECH=1 to install the en-US speech model")
        let last = Last()
        try await AppleSpeechAssets.install(language: "en-US") { last.value = $0 }
        let state = await AppleSpeechAssets.state(for: "en-US")
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(last.value, 1)
    }

    private final class Last: @unchecked Sendable { var value: Double? }

    /// An engine as the app runs it, loaded with `spec`.
    private func loadedEngine() async throws -> TranscriptionEngine {
        try skipUnlessAvailable()
        let engines = EngineRegistry.shared
        try XCTSkipUnless(engines.isPresent(spec), "en-US speech model not installed")
        let engine = TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil),
                                         isPresent: engines.isPresent, makeAdapter: engines.makeAdapter(EngineOptions()))
        engine.load()
        return engine
    }
}
