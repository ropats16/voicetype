import Foundation

/// One token Parakeet decoded: its text, where a leading space starts a new
/// word (SentencePiece's `▁`), and when it was spoken, in seconds from the
/// start of the clip.
struct ParakeetToken: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Groups Parakeet's timed tokens into the engine's segments, so a Parakeet
/// transcript reads like a whisper one: whole-word segments in order, each
/// with a leading space (`Transcript.text` joins them as they are). Pure.
enum ParakeetSegmenter {
    /// A silence between two words at least this long (seconds) starts a new
    /// segment, so unpunctuated speech still splits where the speaker paused.
    static let pauseSeconds: TimeInterval = 0.8

    /// Segments in order, each a run of whole words: a new one starts after
    /// sentence-ending punctuation or a pause of `pauseSeconds`. Control
    /// tokens (`<unk>`, `<|nospeech|>`, …) are dropped, and so is a segment
    /// with no words. Times are clamped to `0...clipDuration` and made
    /// monotonic (a segment never starts before the previous one ended).
    static func segments(from tokens: [ParakeetToken], clipDuration: TimeInterval) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var run: [ParakeetToken] = []
        func close() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            var text = run.map(\.text).joined()
            guard !text.allSatisfy(\.isWhitespace) else { return }
            if text.first?.isWhitespace == false { text = " " + text }
            let floor = segments.last?.end ?? 0
            let start = min(max(first.start, floor), clipDuration)
            let end = min(max(last.end, start), clipDuration)
            segments.append(Transcript.Segment(text: text, start: start, end: end))
        }
        for token in tokens where !isControl(token) {
            if let previous = run.last, startsWord(token),
               endsSentence(previous) || token.start - previous.end >= pauseSeconds { close() }
            run.append(token)
        }
        close()
        return segments
    }

    private static func isControl(_ token: ParakeetToken) -> Bool {
        let text = token.text.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("<") && text.hasSuffix(">")
    }

    private static func startsWord(_ token: ParakeetToken) -> Bool {
        token.text.first?.isWhitespace ?? false
    }

    private static func endsSentence(_ token: ParakeetToken) -> Bool {
        guard let last = token.text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
    }
}
