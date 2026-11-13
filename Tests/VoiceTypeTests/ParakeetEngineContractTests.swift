import XCTest
@testable import VoiceType

/// Contract test for the Parakeet adapter, through the registry and the
/// engine exactly as the app runs it, against the real v3 model folder.
/// Skipped when it's absent (fetch it with `make parakeet-model`).
final class ParakeetEngineContractTests: XCTestCase {

    private let model = ParakeetCatalog.defaultModel

    private func spec(language: String = "en") -> ModelSpec {
        ModelSpec(path: model.folder().path, sha256: nil, language: language, engine: .parakeet)
    }

    /// In-memory checksum cache: keeps these tests from writing the user's.
    private func makeEngine(language: String = "en") throws -> TranscriptionEngine {
        let spec = spec(language: language)
        try XCTSkipUnless(ParakeetEngine().isPresent(spec), "\(model.id) not downloaded")
        return TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil),
                                   isPresent: ParakeetEngine().isPresent,
                                   makeAdapter: TranscriptionEngine.parakeetAdapter(verifier: ModelVerifier(cacheURL: nil)))
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
        let engine = try makeEngine(language: ModelSpec.autoDetect)
        engine.load()
        let empty = try await engine.transcribe([])
        XCTAssertEqual(empty.segments, [])
        let tap = try await engine.transcribe([Float](repeating: 0, count: 1_600))   // 0.1 s
        for segment in tap.segments { XCTAssertLessThanOrEqual(segment.end, 0.1) }
    }

    /// A specific language passes FluidAudio's script hint; decoding still
    /// works (JFK is English, but Latin script like German).
    func testLanguageHintStillTranscribes() async throws {
        let engine = try makeEngine(language: "de")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: EngineContract.jfkPath), "jfk.wav fixture not present")
        engine.load()
        let transcript = try await engine.transcribe(try EngineContract.loadMono16k(EngineContract.jfkPath))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertFalse(transcript.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A catalog folder with a missing file fails the load with a clear
    /// reason; nothing is fetched from the network.
    func testIncompleteFolderFailsTheLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(model.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let make = TranscriptionEngine.parakeetAdapter(verifier: ModelVerifier(cacheURL: nil))
        XCTAssertThrowsError(try make(ModelSpec(path: dir.path, sha256: nil, language: "en", engine: .parakeet))) {
            XCTAssertTrue($0 is ParakeetModelIncomplete, "\($0)")
        }
    }
}
