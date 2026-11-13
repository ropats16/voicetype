import XCTest
@testable import VoiceType

/// Contract test for the WhisperKit adapter, through the registry and the
/// engine exactly as the app runs it (manifest check, load, warm-up), against
/// the real tiny.en Core ML folder and whisper.cpp's bundled JFK sample.
/// Skipped when the folder is absent (fetch it with
/// `make whisperkit-model WHISPERKIT=tiny.en`).
final class WhisperKitEngineContractTests: XCTestCase {

    private let model = WhisperKitCatalog.model(id: "tiny.en")!
    private var spec: ModelSpec { WhisperKitCatalog.spec(for: model, language: "en") }

    func testTranscribesJFK() async throws {
        let transcript = try await EngineContract.assertTranscribesJFK(spec)
        XCTAssertTrue(transcript.text.hasPrefix(" "), "segments carry whisper's leading space: \(transcript.text)")
        XCTAssertNil(transcript.text.range(of: "<|"), "no special tokens: \(transcript.text)")
    }

    func testSilenceYieldsNoTags() async throws {
        let text = try await EngineContract.assertSilenceYieldsNoTags(spec)
        XCTAssertNil(text.range(of: "<|"), "no special tokens: \(text)")
    }

    /// Sub-second clips (a quick "Yes.") and empty ones decode, not throw;
    /// WhisperKit's own 1 s end guard would skip them (`windowClipTime`).
    func testVeryShortClipsDoNotFail() async throws {
        try XCTSkipUnless(WhisperKitEngine().isPresent(spec), "\(model.id) not downloaded")
        let engine = TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil),
                                         makeAdapter: TranscriptionEngine.whisperKitAdapter())
        engine.load()
        for count in [0, 1_600, 8_000] {
            _ = try await engine.transcribe([Float](repeating: 0, count: count))
        }
        XCTAssertEqual(engine.status, .ready)
    }

    /// A folder that doesn't match its pinned manifest fails verification and
    /// is never loaded.
    func testATamperedFolderFailsVerification() async throws {
        try XCTSkipUnless(WhisperKitEngine().isPresent(spec), "\(model.id) not downloaded")
        var spec = spec
        spec.sha256 = String(repeating: "0", count: 64)
        var loads = 0
        let engine = TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil)) { _ in
            loads += 1
            throw TranscriptionError.modelLoadFailed(path: spec.path)
        }
        engine.load()
        let deadline = Date().addingTimeInterval(60)
        while [.loading, .verifying].contains(engine.status), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed = engine.status else { return XCTFail("Expected failed, got \(engine.status)") }
        XCTAssertEqual(loads, 0)
    }

    /// A folder without its tokenizer fails to load instead of fetching one.
    func testAFolderWithoutItsTokenizerFailsOffline() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let make = TranscriptionEngine.whisperKitAdapter()
        XCTAssertThrowsError(try make(ModelSpec(path: empty.path, sha256: nil, language: "en", engine: .whisperKit)))
    }
}
