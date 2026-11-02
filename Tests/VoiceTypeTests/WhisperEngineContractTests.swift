import XCTest
@testable import VoiceType

/// Contract test for the whisper.cpp adapter, run through the engine against
/// the real tiny model and whisper.cpp's bundled JFK sample. Skipped when either
/// file is absent (fetch the model with `make model MODEL=tiny.en`).
final class WhisperEngineContractTests: XCTestCase {

    private let modelPath = Paths.modelsDir.appendingPathComponent("ggml-tiny.en.bin").path
    private let wavPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CWhisper/whisper.cpp/samples/jfk.wav").path

    func testTranscribesJFKSampleIntoOrderedTimestampedSegments() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "tiny.en model not downloaded")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let audio = try WavReader.load(path: wavPath)
        XCTAssertEqual(audio.sampleRate, 16_000)

        let engine = TranscriptionEngine.whisper(modelPath: modelPath, language: "en", threads: 0)
        engine.load()
        let transcript = try await engine.transcribe(audio.samples)

        XCTAssertEqual(engine.status, .ready)
        XCTAssertTrue(transcript.text.lowercased().contains("country"),
                      "Expected the JFK quote, got: \(transcript.text)")
        XCTAssertFalse(transcript.segments.isEmpty)

        let duration = Double(audio.samples.count) / 16_000
        var previousEnd: TimeInterval = 0
        for segment in transcript.segments {
            XCTAssertLessThanOrEqual(previousEnd, segment.start, "Segments must not go back in time")
            XCTAssertLessThanOrEqual(segment.start, segment.end)
            previousEnd = segment.end
        }
        XCTAssertGreaterThan(previousEnd, 1, "Timestamps must be real, not all zero")
        XCTAssertLessThanOrEqual(previousEnd, duration + 0.5, "Timestamps stay within the clip")
    }
}
