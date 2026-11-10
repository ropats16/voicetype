import XCTest
import CWhisper
@testable import VoiceType

/// The whisper.cpp tuning knobs (#7): encoder-context sizing, the mapping onto
/// `whisper_full_params`, the non-speech tag filter, and log silencing.
final class WhisperTuningTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsAreTheBenchChoice() {
        let t = WhisperTuning.default
        XCTAssertFalse(t.suppressNonSpeech, "#7: suppress_nst also bans : / \" etc.; NonSpeechFilter drops tags")
        XCTAssertEqual(t.audioContext, .full)
        XCTAssertTrue(t.temperatureFallback)
        XCTAssertEqual(t.vad, .off)
    }

    func testAutoThreadsArePerformanceCoresCappedAtEight() {
        XCTAssertEqual(WhisperAdapter.autoThreadCount(performanceCores: 12, activeProcessors: 16), 8, "M3 Max")
        XCTAssertEqual(WhisperAdapter.autoThreadCount(performanceCores: 4, activeProcessors: 8), 4,
                       "M1/M2: no efficiency cores")
        XCTAssertEqual(WhisperAdapter.autoThreadCount(performanceCores: nil, activeProcessors: 6), 6, "Intel")
        XCTAssertEqual(WhisperAdapter.autoThreadCount(performanceCores: nil, activeProcessors: 0), 1)
        XCTAssertGreaterThanOrEqual(WhisperAdapter.autoThreadCount(), 1, "this Mac")
    }

    // MARK: - Encoder context sizing

    private func seconds(_ s: Double) -> Int { Int(s * 16_000) }

    func testAudioContextCoversTheClipPlusPaddingInBlocksOf64() {
        // 11 s = 550 frames, + 64 padding = 614 → 640.
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(11)), 640)
        // 20 s = 1000 frames + 64 = 1064 → 1088.
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(20)), 1088)
        // A partial frame counts as a whole one: 320 samples per frame.
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: 320 * 576), 640)
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: 320 * 576 + 1), 704)
    }

    func testAudioContextHasAFloorForVeryShortClips() {
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: 1), Int32(WhisperTuning.minAudioContext))
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(1)), 256)
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(3.5)), 256)
    }

    func testAudioContextFallsBackToTheFullWindowNearAndPast30Seconds() {
        // 28 s = 1400 + 64 = 1464 → 1472, still under 1500.
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(28)), 1472)
        // Rounded past 1500 → 0, whisper.cpp's "use the model's own" (1500).
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(28.5)), 0)
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(30)), 0)
        XCTAssertEqual(WhisperTuning.audioContext(forSampleCount: seconds(600)), 0)
    }

    // MARK: - Mapping onto whisper_full_params

    private func params(_ tuning: WhisperTuning, sampleCount: Int = 16_000 * 11,
                        threads: Int32 = 4) -> whisper_full_params {
        "en".withCString { lang in
            "/models/ggml-silero.bin".withCString { vad in
                WhisperAdapter.fullParams(tuning: tuning, language: lang,
                                          vadModelPath: tuning.vad == .off ? nil : vad,
                                          threads: threads, sampleCount: sampleCount)
            }
        }
    }

    func testDefaultTuningMapsToWhisperCppsOwnDecoding() {
        let p = params(.default)
        XCTAssertFalse(p.suppress_nst)
        XCTAssertEqual(p.audio_ctx, 0)
        XCTAssertEqual(p.temperature, 0)
        XCTAssertEqual(p.temperature_inc, 0.2, accuracy: 1e-6)
        XCTAssertFalse(p.vad)
        XCTAssertNil(p.vad_model_path)
        XCTAssertEqual(p.n_threads, 4)
        XCTAssertFalse(p.translate)
        XCTAssertFalse(p.no_timestamps)
        XCTAssertTrue(p.no_context)
        XCTAssertFalse(p.single_segment)
        XCTAssertFalse(p.print_progress || p.print_realtime || p.print_timestamps || p.print_special)
    }

    func testEveryKnobReachesItsParam() {
        var t = WhisperTuning.default
        t.suppressNonSpeech = true
        t.audioContext = .sizedToClip
        t.temperatureFallback = false
        t.vad = .silero(modelPath: "/models/ggml-silero.bin")
        let p = params(t, sampleCount: 16_000 * 11)
        XCTAssertTrue(p.suppress_nst)
        XCTAssertEqual(p.audio_ctx, 640)
        XCTAssertEqual(p.temperature_inc, 0, "0 = no temperature fallback in whisper.cpp")
        XCTAssertTrue(p.vad)
        XCTAssertEqual(p.vad_model_path.map { String(cString: $0) }, "/models/ggml-silero.bin")
    }

    // MARK: - Report encoding

    func testTuningEncodesFlatWithVADAsNullOrPath() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(WhisperTuning.default), as: UTF8.self),
                       #"{"audioContext":"off","suppressNonSpeech":false,"temperatureFallback":true,"vad":null}"#)

        var t = WhisperTuning.default
        t.audioContext = .sizedToClip
        t.vad = .silero(modelPath: "/m/ggml-silero-v6.2.0.bin")
        let data = try encoder.encode(t)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"audioContext":"clip","suppressNonSpeech":false,"temperatureFallback":true,"vad":"/m/ggml-silero-v6.2.0.bin"}"#)
        XCTAssertEqual(try JSONDecoder().decode(WhisperTuning.self, from: data), t)
    }

    func testSummaryUsesTheBenchFlagVocabulary() {
        XCTAssertEqual(WhisperTuning.default.summary, "suppress-nst off · audio-ctx off · temp-fallback on · vad off")
        var t = WhisperTuning.default
        t.suppressNonSpeech = true
        t.audioContext = .sizedToClip
        t.temperatureFallback = false
        t.vad = .silero(modelPath: "/m/ggml-silero-v6.2.0.bin")
        XCTAssertEqual(t.summary, "suppress-nst on · audio-ctx clip · temp-fallback off · vad ggml-silero-v6.2.0.bin")
    }

    // MARK: - Non-speech tag filter

    func testTagOnlyTextCleansToNothing() {
        for text in [" [BLANK_AUDIO]", "[Music]", " (music)", " (upbeat music)", " [Music] (applause) ♪",
                     " ♪♪", "  [ Silence ]  ", " (in brackets)", "[BLANK_AUDIO] [BLANK_AUDIO]"] {
            XCTAssertEqual(NonSpeechFilter.clean(text), "", "\(text.debugDescription) should clean to nothing")
        }
    }

    func testInlineTagsAreStrippedAndSpacingTidied() {
        XCTAssertEqual(NonSpeechFilter.clean(" Hello [Music] world."), " Hello world.")
        XCTAssertEqual(NonSpeechFilter.clean(" Hello world [BLANK_AUDIO]"), " Hello world")
        XCTAssertEqual(NonSpeechFilter.clean(" [Music] Hello"), " Hello")
        XCTAssertEqual(NonSpeechFilter.clean("[Music] Hello"), "Hello")
        XCTAssertEqual(NonSpeechFilter.clean(" Thanks (laughs)."), " Thanks.")
        XCTAssertEqual(NonSpeechFilter.clean(" Okay (Laughter) so"), " Okay so")
        XCTAssertEqual(NonSpeechFilter.clean(" ♪ la la la ♪"), " la la la")
        XCTAssertEqual(NonSpeechFilter.clean(" Well *sighs* okay."), " Well okay.")
        XCTAssertEqual(NonSpeechFilter.clean(" *Laughs*"), "")
    }

    func testOrdinaryTextAndSpokenParenthesesAreLeftAlone() {
        for text in [" Hello, world.", " The function (which is fine) returns.", "  Two  spaces stay.",
                     " Prices rose 5% (year on year).", " Meet at 3:30 and/or 4, \"he said\".",
                     " Multiply 2 * noise * 3.", " This is *really* important.", ""] {
            XCTAssertEqual(NonSpeechFilter.clean(text), text)
        }
    }

    func testSegmentsThatAreOnlyTagsAreDroppedAndTheRestCleaned() {
        let segments = [
            Transcript.Segment(text: " Hi", start: 0, end: 1),
            Transcript.Segment(text: " [BLANK_AUDIO]", start: 1, end: 2),
            Transcript.Segment(text: " there (music)", start: 2, end: 3),
            Transcript.Segment(text: " (Music)", start: 3, end: 4),
        ]
        XCTAssertEqual(NonSpeechFilter.filter(segments), [
            Transcript.Segment(text: " Hi", start: 0, end: 1),
            Transcript.Segment(text: " there", start: 2, end: 3),
        ])
    }

    // MARK: - Log silencing

    func testOnlyWarningsAndErrorsAreForwardedAndThoseOnlyAtDebug() {
        XCTAssertFalse(WhisperLogging.forwards(GGML_LOG_LEVEL_INFO))
        XCTAssertFalse(WhisperLogging.forwards(GGML_LOG_LEVEL_DEBUG))
        XCTAssertFalse(WhisperLogging.forwards(GGML_LOG_LEVEL_CONT))
        XCTAssertFalse(WhisperLogging.forwards(GGML_LOG_LEVEL_NONE))
        XCTAssertTrue(WhisperLogging.forwards(GGML_LOG_LEVEL_WARN))
        XCTAssertTrue(WhisperLogging.forwards(GGML_LOG_LEVEL_ERROR))
    }

    func testInstallingTheLogSinkIsIdempotent() {
        WhisperLogging.install()
        WhisperLogging.install()
        XCTAssertTrue(WhisperLogging.isInstalled)
    }
}
