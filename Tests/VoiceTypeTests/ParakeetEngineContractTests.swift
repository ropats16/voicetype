import XCTest
@testable import VoiceType

/// Contract test for the Parakeet adapter, through the registry and the
/// engine exactly as the app runs it (manifest check, load, warm-up), against
/// the real v3 model folder. Skipped when it's absent (fetch it with
/// `make parakeet-model`).
final class ParakeetEngineContractTests: XCTestCase {

    private let model = ParakeetCatalog.defaultModel

    /// The installed folder, as the app resolves it: verified against its
    /// pinned manifest.
    private func spec(language: String = "en") -> ModelSpec {
        ParakeetEngine().resolve(.automatic, in: ModelContext(language: language, hardware: .current,
                                                              modelsDir: Paths.modelsDir, presentFilenames: []))
    }

    /// In-memory checksum cache: keeps these tests from writing the user's.
    private func makeEngine(_ spec: ModelSpec, makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter
                                = TranscriptionEngine.parakeetAdapter()) throws -> TranscriptionEngine {
        try XCTSkipUnless(ParakeetEngine().isPresent(spec), "\(model.id) not downloaded")
        return TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil),
                                   isPresent: ParakeetEngine().isPresent, makeAdapter: makeAdapter)
    }

    func testTranscribesJFK() async throws {
        let transcript = try await EngineContract.assertTranscribesJFK(spec())
        XCTAssertEqual(transcript.segments.first?.text.first, " ", "segments carry whisper's leading space")
        for segment in transcript.segments {
            XCTAssertFalse(segment.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Silence decodes to nothing: no tags, no hallucinated words.
    func testSilenceYieldsNothing() async throws {
        let text = try await EngineContract.assertSilenceYieldsNoTags(spec())
        XCTAssertEqual(text.trimmingCharacters(in: .whitespaces), "")
    }

    /// Clips under FluidAudio's 0.3 s minimum (a tap of the hotkey), and
    /// empty ones, transcribe instead of throwing.
    func testVeryShortClipsDoNotFail() async throws {
        let engine = try makeEngine(spec())
        engine.load()
        let empty = try await engine.transcribe([])
        XCTAssertEqual(empty.segments, [])
        let tap = try await engine.transcribe([Float](repeating: 0, count: 1_600))   // 0.1 s
        for segment in tap.segments { XCTAssertLessThanOrEqual(segment.end, 0.1) }
    }

    /// A specific language passes FluidAudio's script hint; decoding still
    /// works (JFK is English, but Latin script like German).
    func testLanguageHintStillTranscribes() async throws {
        let engine = try makeEngine(spec(language: "de"))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: EngineContract.jfkPath), "jfk.wav fixture not present")
        engine.load()
        let transcript = try await engine.transcribe(try EngineContract.loadMono16k(EngineContract.jfkPath))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertFalse(transcript.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A folder that doesn't match its pinned manifest fails verification and
    /// is never loaded.
    func testATamperedFolderFailsVerification() async throws {
        var spec = spec()
        spec.sha256 = String(repeating: "0", count: 64)
        var loads = 0
        let engine = try makeEngine(spec) { _ in
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
}
