import Foundation

/// Turns a raw transcript into the text to deliver.
enum TranscriptCleanup {
    /// Drops non-speech tags (`NonSpeechFilter`: tag-only text becomes "",
    /// inline tags are removed) and trims whitespace. Non-empty text gets a
    /// trailing space if asked. Returns "" when there is nothing to deliver.
    /// The whisper adapter already filters each segment; this repeats it on
    /// the whole transcript so every engine gets the same rule.
    static func clean(_ raw: String, trailingSpace: Bool) -> String {
        var text = NonSpeechFilter.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && trailingSpace { text += " " }
        return text
    }
}
