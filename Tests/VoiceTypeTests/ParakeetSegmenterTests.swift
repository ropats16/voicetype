import XCTest
@testable import VoiceType

/// Parakeet emits timed sub-word tokens; the segmenter groups them into the
/// engine's timestamped segments, joined the way `Transcript.text` expects.
final class ParakeetSegmenterTests: XCTestCase {

    private func t(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> ParakeetToken {
        ParakeetToken(text: text, start: start, end: end)
    }

    func testSplitsAfterSentenceEndingPunctuation() {
        let segments = ParakeetSegmenter.segments(from: [
            t(" And", 0.0, 0.3), t(" so", 0.3, 0.5), t(".", 0.5, 0.6),
            t(" My", 1.0, 1.2), t(" fel", 1.2, 1.3), t("low", 1.3, 1.5),
        ], clipDuration: 2)

        XCTAssertEqual(segments, [
            Transcript.Segment(text: " And so.", start: 0.0, end: 0.6),
            Transcript.Segment(text: " My fellow", start: 1.0, end: 1.5),
        ])
    }

    /// Unpunctuated speech still splits where the speaker paused.
    func testSplitsAtALongPauseBetweenWords() {
        let segments = ParakeetSegmenter.segments(from: [
            t(" first", 0.0, 0.4), t(" part", 0.5, 0.9),
            t(" second", 2.0, 2.4), t(" part", 2.5, 2.9),
        ], clipDuration: 3)

        XCTAssertEqual(segments.map(\.text), [" first part", " second part"])
        XCTAssertEqual(segments.map(\.start), [0.0, 2.0])
        XCTAssertEqual(segments.map(\.end), [0.9, 2.9])
    }

    /// A short gap, or punctuation inside a word ("3.5"), is not a boundary.
    func testKeepsWordsAndShortGapsTogether() {
        let segments = ParakeetSegmenter.segments(from: [
            t(" version", 0.0, 0.4), t(" 3", 0.6, 0.7), t(".", 0.7, 0.8), t("5", 1.5, 1.6),
        ], clipDuration: 2)

        XCTAssertEqual(segments.map(\.text), [" version 3.5"])
    }

    /// Times stay inside the clip and never go back, even when the decoder's
    /// frame timings overshoot (padding) or overlap (window seams).
    func testTimestampsStayInTheClipAndInOrder() {
        let segments = ParakeetSegmenter.segments(from: [
            t(" one", 0.0, 0.5), t(".", 0.5, 0.6),
            t(" two", 0.4, 0.9), t(".", 0.9, 1.0),
            t(" three", 1.1, 1.8),
        ], clipDuration: 1.5)

        XCTAssertEqual(segments.map(\.text), [" one.", " two.", " three"])
        var previousEnd: TimeInterval = 0
        for segment in segments {
            XCTAssertLessThanOrEqual(previousEnd, segment.start)
            XCTAssertLessThanOrEqual(segment.start, segment.end)
            XCTAssertLessThanOrEqual(segment.end, 1.5)
            previousEnd = segment.end
        }
    }

    /// Control tokens (`<|nospeech|>`, `<unk>`) never reach the text; the
    /// first word gets the leading space whisper's segments carry; nothing
    /// decoded means no segments.
    func testDropsControlTokensAndNormalizesSpacing() {
        XCTAssertEqual(ParakeetSegmenter.segments(from: [
            t("<|nospeech|>", 0, 0.1), t("Hello", 0.2, 0.5), t("<unk>", 0.5, 0.6), t(" there", 0.6, 0.9),
        ], clipDuration: 1).map(\.text), [" Hello there"])
        XCTAssertEqual(ParakeetSegmenter.segments(from: [t("<|nospeech|>", 0, 0.1), t(" ", 0.1, 0.2)],
                                                  clipDuration: 1), [])
        XCTAssertEqual(ParakeetSegmenter.segments(from: [], clipDuration: 1), [])
    }
}
