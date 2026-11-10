import Foundation

/// Turns a raw transcript into the text to deliver.
enum TranscriptCleanup {
    /// One `[...]` or `(...)` tag, e.g. whisper.cpp's `[BLANK_AUDIO]` or `(music)`.
    private static let tagOnly = try! NSRegularExpression(
        pattern: #"^(?:\s*(?:\[[^\[\]]*\]|\([^()]*\)))+\s*$"#)

    /// Trims whitespace and drops output that is only non-speech tags
    /// (`[BLANK_AUDIO]`, `(music)`, `[Music] [Applause]`); speech containing
    /// tags is kept as-is. Non-empty text gets a trailing space if asked.
    /// Returns "" when there is nothing to deliver.
    static func clean(_ raw: String, trailingSpace: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        if tagOnly.firstMatch(in: text, range: range) != nil { text = "" }
        if !text.isEmpty && trailingSpace { text += " " }
        return text
    }
}
