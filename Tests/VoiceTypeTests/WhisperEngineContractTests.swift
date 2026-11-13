import XCTest
@testable import VoiceType

/// The shared `EngineContract` for the whisper.cpp adapter, through the app's
/// registry, against the real tiny model. Skipped when the model is absent
/// (fetch it with `make model MODEL=tiny.en`).
final class WhisperEngineContractTests: XCTestCase {

    /// Unverified: keeps these tests from writing the user's checksum cache.
    private func model(_ id: String) -> ModelSpec {
        ModelSpec(path: Paths.modelsDir.appendingPathComponent(WhisperModel.filename(for: id)).path,
                  sha256: nil, language: "en", engine: .whisper)
    }

    func testTranscribesJFKSampleIntoOrderedTimestampedSegments() async throws {
        try await EngineContract.assertTranscribesJFK(model("tiny.en"))
    }

    /// #7: silence decodes to no tags (`[BLANK_AUDIO]`, `(music)`, …), with
    /// the app's default tuning.
    func testSilenceNeverYieldsNonSpeechTags() async throws {
        try await EngineContract.assertSilenceYieldsNoTags(model("tiny.en"))
    }

    /// medium.en (the default on most Macs) emits `[BLANK_AUDIO]` on silence,
    /// and hallucinates "you" if `suppress_nst` is on: expect empty text.
    func testSilenceYieldsNothingOnMediumEn() async throws {
        let text = try await EngineContract.assertSilenceYieldsNoTags(model("medium.en"))
        XCTAssertEqual(text.trimmingCharacters(in: .whitespaces), "")
    }

    /// Every non-default knob together still transcribes the JFK sample.
    func testTunedDecodingStillTranscribesJFK() async throws {
        let vadPath = Paths.modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: vadPath),
                          "Silero VAD model not downloaded (scripts/download_vad_model.sh)")
        let tuning = WhisperTuning(suppressNonSpeech: true, audioContext: .sizedToClip,
                                   temperatureFallback: false, vad: .silero(modelPath: vadPath))
        try await EngineContract.assertTranscribesJFK(model("tiny.en"), options: EngineOptions(threads: 4, whisper: tuning))
    }

    /// A missing VAD model fails the load, not every job.
    func testMissingVADModelFailsTheLoad() async throws {
        let spec = model("tiny.en")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: spec.path), "tiny.en model not downloaded")
        let make = TranscriptionEngine.whisperAdapter(
            threads: 0, tuning: WhisperTuning(vad: .silero(modelPath: "/nonexistent/ggml-silero.bin")))
        XCTAssertThrowsError(try make(spec))
    }
}
