import XCTest
import AVFoundation
@testable import VoiceType

/// The contract every real engine adapter passes, run through
/// `TranscriptionEngine` exactly as the app runs it (presence check, load,
/// warm-up, job queue) against whisper.cpp's bundled JFK sample:
///
/// - the JFK quote comes back (the text contains "country"), as non-empty
///   segments whose timestamps are real (last end > 1 s), ordered (never back
///   in time, start ≤ end) and within the clip (+0.5 s);
/// - 3 s of silence yields no non-speech tags (`[BLANK_AUDIO]`, `(music)`, ♪, *…*).
///
/// Each check skips (not fails) when the sample or the model isn't installed,
/// so the suite passes on a fresh checkout. An adapter's contract test is:
///
/// ```swift
/// func testJFK() async throws {
///     let spec = ModelSpec(path: <installed model>, sha256: nil, language: "en", engine: .parakeet)
///     try await EngineContract.assertTranscribesJFK(spec)       // via EngineRegistry.shared
/// }
/// func testSilence() async throws {
///     try await EngineContract.assertSilenceYieldsNoTags(spec)
/// }
/// ```
///
/// Pass `engines:` for a registry other than `.shared`, or `isPresent:` and
/// `makeAdapter:` to test a factory that isn't registered yet.
enum EngineContract {

    /// whisper.cpp's JFK sample: 11 s, 16 kHz mono.
    static let jfkPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CWhisper/whisper.cpp/samples/jfk.wav").path

    // MARK: - Through a registry

    /// The JFK check with `spec`'s engine from `engines`, built with `options`.
    @discardableResult
    static func assertTranscribesJFK(_ spec: ModelSpec, engines: EngineRegistry = .shared,
                                     options: EngineOptions = EngineOptions(),
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> Transcript {
        try await assertTranscribesJFK(spec, isPresent: engines.isPresent, makeAdapter: engines.makeAdapter(options),
                                       file: file, line: line)
    }

    /// The silence check with `spec`'s engine from `engines`; returns the text.
    @discardableResult
    static func assertSilenceYieldsNoTags(_ spec: ModelSpec, engines: EngineRegistry = .shared,
                                          options: EngineOptions = EngineOptions(),
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        try await assertSilenceYieldsNoTags(spec, isPresent: engines.isPresent,
                                            makeAdapter: engines.makeAdapter(options), file: file, line: line)
    }

    // MARK: - Through a bare factory

    @discardableResult
    static func assertTranscribesJFK(_ spec: ModelSpec,
                                     isPresent: @escaping (ModelSpec) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                                     makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter,
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> Transcript {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: jfkPath), "jfk.wav fixture not present")
        try XCTSkipUnless(isPresent(spec), "\(spec.displayName) not installed")
        let samples = try loadMono16k(jfkPath)
        let engine = makeEngine(spec, isPresent: isPresent, makeAdapter: makeAdapter)

        engine.load()
        let transcript = try await engine.transcribe(samples)

        XCTAssertEqual(engine.status, .ready, file: file, line: line)
        XCTAssertTrue(transcript.text.lowercased().contains("country"),
                      "Expected the JFK quote, got: \(transcript.text)", file: file, line: line)
        XCTAssertFalse(transcript.segments.isEmpty, file: file, line: line)

        let duration = Double(samples.count) / AudioCapture.sampleRate
        var previousEnd: TimeInterval = 0
        for segment in transcript.segments {
            XCTAssertLessThanOrEqual(previousEnd, segment.start, "Segments must not go back in time: \(segment)",
                                     file: file, line: line)
            XCTAssertLessThanOrEqual(segment.start, segment.end, "\(segment)", file: file, line: line)
            previousEnd = segment.end
        }
        XCTAssertGreaterThan(previousEnd, 1, "Timestamps must be real, not all zero", file: file, line: line)
        XCTAssertLessThanOrEqual(previousEnd, duration + 0.5, "Timestamps stay within the clip", file: file, line: line)
        return transcript
    }

    @discardableResult
    static func assertSilenceYieldsNoTags(_ spec: ModelSpec,
                                          isPresent: @escaping (ModelSpec) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                                          makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        try XCTSkipUnless(isPresent(spec), "\(spec.displayName) not installed")
        let engine = makeEngine(spec, isPresent: isPresent, makeAdapter: makeAdapter)
        engine.load()
        let transcript = try await engine.transcribe([Float](repeating: 0, count: 16_000 * 3))
        XCTAssertEqual(engine.status, .ready, file: file, line: line)
        XCTAssertNil(transcript.text.rangeOfCharacter(from: CharacterSet(charactersIn: "[]()♪*")),
                     "Got tags: \(transcript.text)", file: file, line: line)
        return transcript.text
    }

    // MARK: - Helpers

    /// An engine as the app builds it, with an in-memory checksum cache so a
    /// test never writes the user's.
    private static func makeEngine(_ spec: ModelSpec, isPresent: @escaping (ModelSpec) -> Bool,
                                   makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter) -> TranscriptionEngine {
        TranscriptionEngine(model: spec, verifier: ModelVerifier(cacheURL: nil), isPresent: isPresent,
                            makeAdapter: makeAdapter)
    }

    /// The fixture is already 16 kHz mono, so read it straight, without the
    /// capture's resampler.
    static func loadMono16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
