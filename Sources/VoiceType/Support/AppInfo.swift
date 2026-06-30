import Foundation

/// Static identity & shared constants for the app.
enum AppInfo {
    static let name = "VoiceType"
    static let bundleID = "com.local.VoiceType"

    /// Default Whisper model filename fetched by setup.
    static let defaultModelFilename = "ggml-medium.en.bin"
}
