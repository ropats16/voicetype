import XCTest
import AVFoundation
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
        let samples = try loadMono16k(wavPath)

        let engine = TranscriptionEngine.whisper(
            // Unverified: keeps this test from writing the user's checksum cache.
            model: ModelSpec(path: modelPath, sha256: nil, language: "en"), threads: 0)
        engine.load()
        let transcript = try await engine.transcribe(samples)

        XCTAssertEqual(engine.status, .ready)
        XCTAssertTrue(transcript.text.lowercased().contains("country"),
                      "Expected the JFK quote, got: \(transcript.text)")
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

    /// #7: silence decodes to no tags (`[BLANK_AUDIO]`, `(music)`, …), with
    /// the app's default tuning.
    func testSilenceNeverYieldsNonSpeechTags() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "tiny.en model not downloaded")
        let engine = TranscriptionEngine.whisper(model: ModelSpec(path: modelPath, sha256: nil, language: "en"), threads: 0)
        engine.load()
        let transcript = try await engine.transcribe([Float](repeating: 0, count: 16_000 * 3))
        XCTAssertNil(transcript.text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪")),
                     "Got tags: \(transcript.text)")
    }

    /// Every non-default knob together still transcribes the JFK sample.
    func testTunedDecodingStillTranscribesJFK() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "tiny.en model not downloaded")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let vadPath = Paths.modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: vadPath),
                          "Silero VAD model not downloaded (scripts/download_vad_model.sh)")
        let tuning = WhisperTuning(suppressNonSpeech: true, audioContext: .sizedToClip,
                                   temperatureFallback: false, vad: .silero(modelPath: vadPath))
        let engine = TranscriptionEngine.whisper(model: ModelSpec(path: modelPath, sha256: nil, language: "en"),
                                                 threads: 4, tuning: tuning)
        engine.load()
        let transcript = try await engine.transcribe(try loadMono16k(wavPath))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertTrue(transcript.text.lowercased().contains("country"), "Got: \(transcript.text)")
    }

    /// A missing VAD model fails the load, not every job.
    func testMissingVADModelFailsTheLoad() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelPath), "tiny.en model not downloaded")
        let make = TranscriptionEngine.whisperAdapter(
            threads: 0, tuning: WhisperTuning(vad: .silero(modelPath: "/nonexistent/ggml-silero.bin")))
        XCTAssertThrowsError(try make(ModelSpec(path: modelPath, sha256: nil, language: "en")))
    }

    /// The fixture is already 16 kHz mono, so read it straight, without the
    /// capture's resampler.
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
