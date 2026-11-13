import XCTest
import AVFoundation
@testable import VoiceType

/// Contract test for Apple's SpeechAnalyzer adapter (#14), run through the
/// engine against whisper.cpp's bundled JFK sample. Skipped below macOS 26 and
/// when the en-US speech model isn't on this Mac (install it with
/// `AppleSpeechAssets.install`, or by using Dictation/Live Captions in English).
final class AppleSpeechEngineContractTests: XCTestCase {

    private let wavPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CWhisper/whisper.cpp/samples/jfk.wav").path

    private func makeEngine(language: String = "en-US") async throws -> TranscriptionEngine {
        guard #available(macOS 26, *), AppleSpeechAvailability.isAvailable() else {
            throw XCTSkip("Apple SpeechAnalyzer needs macOS 26")
        }
        let state = await AppleSpeechAssets.state(for: language)
        try XCTSkipUnless(state == .installed, "\(language) speech model not installed (\(state))")
        let engine = TranscriptionEngine(model: .appleSpeech(language: language),
                                         makeAdapter: TranscriptionEngine.appleSpeechAdapter())
        engine.load()
        return engine
    }

    func testTranscribesJFKSampleIntoOrderedTimestampedSegments() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let samples = try loadMono16k(wavPath)
        let engine = try await makeEngine()

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

    /// Fed as one buffer, the transcriber silently kept only the last ~2.5
    /// minutes of a long clip; every repeat of the quote must come back.
    func testTranscribesAllOfALongClip() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let jfk = try loadMono16k(wavPath)
        let repeats = 30   // 5.5 minutes
        let engine = try await makeEngine()

        let transcript = try await engine.transcribe(Array([[Float]](repeating: jfk, count: repeats).joined()))

        let mentions = transcript.text.lowercased().components(separatedBy: "country").count - 1
        XCTAssertEqual(mentions, 2 * repeats, "Got \(transcript.text.count) characters")
        XCTAssertLessThan(transcript.segments.first?.start ?? .infinity, 1)
    }

    func testSilenceYieldsNoText() async throws {
        let engine = try await makeEngine()
        let transcript = try await engine.transcribe([Float](repeating: 0, count: 16_000 * 3))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertNil(transcript.text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*")),
                     "Got tags: \(transcript.text)")
        XCTAssertEqual(transcript.text.trimmingCharacters(in: .whitespaces), "")
    }

    /// "auto" can't detect: it transcribes in the Mac's language, which here
    /// must be one the transcriber has (any English does for this clip).
    func testAutoLanguageTranscribes() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavPath), "jfk.wav fixture not present")
        let engine = try await makeEngine(language: ModelSpec.autoDetect)
        let transcript = try await engine.transcribe(try loadMono16k(wavPath))
        XCTAssertEqual(engine.status, .ready)
        XCTAssertFalse(transcript.text.isEmpty)
    }

    /// An unsupported language fails the load with a reason the user can act
    /// on, never a download.
    func testUnsupportedLanguageFailsTheLoad() async throws {
        guard #available(macOS 26, *), AppleSpeechAvailability.isAvailable() else {
            throw XCTSkip("Apple SpeechAnalyzer needs macOS 26")
        }
        let make = TranscriptionEngine.appleSpeechAdapter()
        XCTAssertThrowsError(try make(.appleSpeech(language: "xx"))) {
            XCTAssertEqual($0 as? AppleSpeechError, .unsupportedLanguage("xx"))
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
