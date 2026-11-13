import XCTest
@testable import VoiceType

/// WhisperKit's raw segments → the app's: special tokens and non-speech tags
/// gone, spacing as whisper.cpp's (one leading space), times kept. Pure.
final class WhisperKitAdapterTests: XCTestCase {

    private func seg(_ text: String, _ start: TimeInterval = 0, _ end: TimeInterval = 1) -> Transcript.Segment {
        Transcript.Segment(text: text, start: start, end: end)
    }

    func testSegmentsReadLikeWhisperCppOnes() {
        let out = WhisperKitAdapter.normalize([seg("And so my fellow Americans,", 0, 3.2),
                                               seg("  ask not what your country can do for you. ", 3.2, 7.5)])
        XCTAssertEqual(out, [seg(" And so my fellow Americans,", 0, 3.2),
                             seg(" ask not what your country can do for you.", 3.2, 7.5)])
        XCTAssertEqual(Transcript(segments: out).text,
                       " And so my fellow Americans, ask not what your country can do for you.")
    }

    func testSpecialTokensAreStripped() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> And so my fellow Americans<|4.20|>"
        XCTAssertEqual(WhisperKitAdapter.normalize([seg(raw, 0, 4.2)]), [seg(" And so my fellow Americans", 0, 4.2)])
    }

    /// WhisperKit won't start a window in a clip's last `windowClipTime`
    /// seconds (default 1 s), so a sub-second "Yes." — or the engine's 1 s
    /// warm-up — would decode nothing. Short clips get a shorter guard.
    func testShortClipsStillGetDecoded() {
        for seconds in [0.2, 0.5, 1.0, 1.5] {
            let clip = WhisperKitAdapter.windowClipTime(forSampleCount: Int(seconds * 16_000))
            XCTAssertLessThan(Double(clip), seconds, "a \(seconds)s clip gets a window")
            XCTAssertGreaterThan(clip, 0, "but keeps some guard")
        }
        XCTAssertEqual(WhisperKitAdapter.windowClipTime(forSampleCount: 5 * 16_000), 1.0, "WhisperKit's default")
        XCTAssertEqual(WhisperKitAdapter.windowClipTime(forSampleCount: 600 * 16_000), 1.0)
    }

    func testTokenOnlyAndTagOnlySegmentsAreDropped() {
        let out = WhisperKitAdapter.normalize([seg("<|endoftext|>"), seg(" [BLANK_AUDIO]"), seg(" (music)"),
                                               seg("   "), seg(" Hello [Music] world", 2, 3)])
        XCTAssertEqual(out, [seg(" Hello world", 2, 3)])
    }
}
