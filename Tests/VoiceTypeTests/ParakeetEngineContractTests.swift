import XCTest
import AVFoundation
@testable import VoiceType

/// Contract test for the Parakeet adapter, run through the engine against the
/// real v3 model folder and whisper.cpp's bundled JFK sample. Skipped when
/// either is absent (fetch the model with `make parakeet-model`).
final class ParakeetEngineContractTests: XCTestCase {

    private let model = ParakeetCatalog.defaultModel
    private var folder: String { model.folder().path }
    private let wavPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CWhisper/whisper.cpp/samples/jfk.wav").path

    /// In-memory checksum cache: keeps these tests from writing the user's.
    private func makeEngine(language: String = "en") throws -> TranscriptionEngine {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder), "\(model.id) not downloaded")
        return TranscriptionEngine(
            model: ModelSpec(path: folder, sha256: nil, language: language),
            makeAdapter: TranscriptionEngine.parakeetAdapter(verifier: ModelVerifier(cacheURL: nil)))
    }

    func testTranscribesJFKSampleIntoOrderedTimestampedSegments() async throws {
        let engine = try makeEngine()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let samples = try loadMono16k(wavPath)

        engine.load()
        let transcript = try await engine.transcribe(samples)

        XCTAssertEqual(engine.status, .ready)
        XCTAssertTrue(transcript.text.lowercased().contains("country"),
                      "Expected the JFK quote, got: \(transcript.text)")
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.segments.first?.text.first, " ", "segments carry whisper's leading space")

        let duration = Double(samples.count) / 16_000
        var previousEnd: TimeInterval = 0
        for segment in transcript.segments {
            XCTAssertFalse(segment.text.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertLessThanOrEqual(previousEnd, segment.start, "Segments must not go back in time")
            XCTAssertLessThanOrEqual(segment.start, segment.end)
            previousEnd = segment.end
        }
        XCTAssertGreaterThan(previousEnd, 1, "Timestamps must be real, not all zero")
        XCTAssertLessThanOrEqual(previousEnd, duration + 0.5, "Timestamps stay within the clip")
    }

    /// Silence decodes to nothing: no tags, no hallucinated words.
    func testSilenceYieldsNothing() async throws {
        let engine = try makeEngine()
        engine.load()
        let transcript = try await engine.transcribe([Float](repeating: 0, count: 16_000 * 3))
        XCTAssertNil(transcript.text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*")),
                     "Got tags: \(transcript.text)")
        XCTAssertEqual(transcript.text.trimmingCharacters(in: .whitespaces), "")
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
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        engine.load()
        let transcript = try await engine.transcribe(try loadMono16k(wavPath))
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
        XCTAssertThrowsError(try make(ModelSpec(path: dir.path, sha256: nil, language: "en"))) { error in
            XCTAssertTrue(error is ParakeetModelIncomplete, "\(error)")
        }
    }

    /// The fixture is already 16 kHz mono, so read it straight.
    private func loadMono16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
