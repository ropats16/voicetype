import Foundation

/// Removes whisper's non-speech tags (`[BLANK_AUDIO]`, `[Music]`, `(music)`,
/// `(laughs)`, `*sighs*`, `♪`) from transcripts, so they never reach the
/// user's text. This is the app's only guard: `suppress_nst` is off by default
/// (`WhisperTuning`), since it would also ban `:`, `/`, quotes, … at decode time.
///
/// - A segment that is nothing but tags (bracketed or parenthesized, any
///   content) is dropped.
/// - Inside speech, `[...]` and music symbols are always removed (whisper
///   never writes square brackets for spoken words); `(...)` and `*...*` only
///   when they are a sound caption: at most three words ending in a sound word
///   (`(laughs)`, `(upbeat music)`, `(speaking foreign language)`), so spoken
///   asides like `(the music industry)` or `(static typing)` stay; `*...*`
///   only as a standalone word (`*sighs*`, not `2*x and music*3`).
enum NonSpeechFilter {
    /// Segments with their tags removed; tag-only segments dropped. Times are kept.
    static func filter(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        segments.compactMap { segment in
            let text = clean(segment.text)
            if text == segment.text { return segment }
            guard !text.allSatisfy(\.isWhitespace) else { return nil }
            return Transcript.Segment(text: text, start: segment.start, end: segment.end)
        }
    }

    /// `text` without its tags: "" if it was only tags; unchanged if it had
    /// none. Otherwise spacing is tidied (one space where a tag was, none
    /// before punctuation or at the end) and a leading space, which whisper
    /// uses to join segments, is kept.
    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        if tagOnly.firstMatch(in: text, range: range) != nil { return "" }
        guard inlineTag.firstMatch(in: text, range: range) != nil else { return text }

        var out = inlineTag.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespaces)
        guard !out.isEmpty else { return "" }
        return text.first?.isWhitespace == true ? " " + out : out
    }

    private static let musicSymbols = "♪♫♬♩"

    /// Whole text = one or more tags (and whitespace).
    private static let tagOnly = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\[[^\[\]]*\]|\([^()]*\)|[\#(musicSymbols)]+)\s*)+$"#)

    /// A tag inside speech: any `[...]`, music symbols, or a `(...)` or
    /// standalone `*...*` sound caption.
    private static let inlineTag = try! NSRegularExpression(
        pattern: #"\[[^\[\]]*\]|[\#(musicSymbols)]+|\(\s*"#  + caption + #"\s*\)|(?<![\w*])\*"#
            + caption + #"\*(?![\w*])"#,
        options: [.caseInsensitive])

    /// Up to two leading words, then a sound word (`upbeat music`, `laughs`).
    private static let caption = #"(?:[\w'-]+\s+){0,2}(?:"# + soundWords.joined(separator: "|") + #")"#

    /// Words whisper's sound captions end in, as regex fragments.
    private static let soundWords = [
        "music", "laugh\\w*", "applause", "silence", "inaudible", "unintelligible", "indistinct", "noise",
        "cough\\w*", "sigh\\w*", "static", "beep\\w*", "breath\\w*", "clap\\w*", "chuckl\\w*", "crosstalk",
        "chatter\\w*", "blank_audio", "whoosh\\w*", "gasp\\w*", "whisper(?:s|ing)", "sniff\\w*", "groan\\w*",
        "sobs?", "sobbing", "cr(?:ies|ying)", "scream\\w*", "hum(?:s|ming)", "sneez\\w*", "yawn\\w*", "footsteps",
        "foreign language",
    ]
}
