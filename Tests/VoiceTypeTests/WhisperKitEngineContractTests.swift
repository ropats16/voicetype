import XCTest
import AVFoundation
@testable import VoiceType

/// Contract test for the WhisperKit adapter, run through the engine against
/// the real tiny.en Core ML model and whisper.cpp's bundled JFK sample.
/// Skipped when either is absent (fetch the model with
/// `make model ENGINE=whisperkit MODEL=tiny.en`).
final class WhisperKitEngineContractTests: XCTestCase {

    private let model = WhisperKitCatalog.model(id: "tiny.en")!
    private var modelFolder: String { WhisperKitCatalog.folder(for: model).path }
    private let wavPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CWhisper/whisper.cpp/samples/jfk.wav").path

    /// Verified against the pinned manifest, with a private cache so the
    /// user's checksum sidecar is left alone.
    private func makeEngine() -> TranscriptionEngine {
        TranscriptionEngine(model: WhisperKitCatalog.spec(for: model, language: "en"),
                            verifier: ModelVerifier(cacheURL: nil),
                            makeAdapter: TranscriptionEngine.whisperKitAdapter())
    }

    private func waitForLoad(_ engine: TranscriptionEngine) async throws {
        let deadline = Date().addingTimeInterval(600)   // a first Core ML specialization can be slow
        while [.loading, .verifying].contains(engine.status), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTranscribesJFKSampleIntoOrderedTimestampedSegments() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelFolder), "WhisperKit tiny.en not downloaded")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let samples = try loadMono16k(wavPath)

        let engine = makeEngine()
        engine.load()
        try await waitForLoad(engine)
        XCTAssertEqual(engine.status, .ready)
        let transcript = try await engine.transcribe(samples)

        XCTAssertTrue(transcript.text.lowercased().contains("country"),
                      "Expected the JFK quote, got: \(transcript.text)")
        XCTAssertTrue(transcript.text.hasPrefix(" "), "Segments read like whisper.cpp's: \(transcript.text)")
        XCTAssertNil(transcript.text.range(of: "<|"), "No special tokens: \(transcript.text)")
        XCTAssertFalse(transcript.segments.isEmpty)

        let duration = Double(samples.count) / 16_000
        var previousEnd: TimeInterval = 0
        for segment in transcript.segments {
            XCTAssertLessThanOrEqual(previousEnd, segment.start, "Segments must not go back in time")
            XCTAssertLessThanOrEqual(segment.start, segment.end)
            previousEnd = segment.end
        }
        XCTAssertGreaterThan(previousEnd, 1, "Timestamps must be real, not all zero")
        XCTAssertLessThanOrEqual(previousEnd, duration + 0.5, "Timestamps stay within the clip")
    }

    func testSilenceNeverYieldsNonSpeechTags() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelFolder), "WhisperKit tiny.en not downloaded")
        let engine = makeEngine()
        engine.load()
        let transcript = try await engine.transcribe([Float](repeating: 0, count: 16_000 * 3))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertNil(transcript.text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*<>")),
                     "Got tags: \(transcript.text)")
    }

    /// A tampered model folder fails its manifest check and is never loaded.
    func testATamperedFolderFailsVerification() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelFolder), "WhisperKit tiny.en not downloaded")
        var spec = WhisperKitCatalog.spec(for: model, language: "en")
        spec.sha256 = String(repeating: "0", count: 64)
        var loads = 0
        let engine = TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil)) { _ in
            loads += 1
            throw TranscriptionError.modelLoadFailed(path: spec.path)
        }
        engine.load()
        try await waitForLoad(engine)
        guard case .failed = engine.status else { return XCTFail("Expected failed, got \(engine.status)") }
        XCTAssertEqual(loads, 0)
    }

    /// A folder without its tokenizer fails to load instead of fetching one.
    func testAFolderWithoutItsTokenizerFailsOffline() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let make = TranscriptionEngine.whisperKitAdapter()
        XCTAssertThrowsError(try make(ModelSpec(path: empty.path, sha256: nil, language: "en")))
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
