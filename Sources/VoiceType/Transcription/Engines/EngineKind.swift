import Foundation

/// Every speech engine VoiceType knows by name. The raw value is the one id
/// used wherever text names an engine: `config.json`'s `engine` key, the keys
/// of `engineModels`, and `--bench --engine`.
///
/// Knowing a kind doesn't make it runnable: only engines with a descriptor in
/// `EngineRegistry.shared` are, and only where their `availability` says so.
/// The rest fall back to whisper (see `EngineRegistry.select`).
enum EngineKind: String, CaseIterable, Codable, Hashable {
    /// whisper.cpp (Metal). Always registered and always available: the fallback.
    case whisper
    /// WhisperKit (Core ML / Neural Engine).
    case whisperKit = "whisperkit"
    /// NVIDIA Parakeet via FluidAudio: opt-in, English + EU languages only.
    case parakeet
    /// Apple's on-device SpeechAnalyzer (macOS 26), with OS-managed models.
    case appleSpeech = "apple-speech"

    /// What Settings and messages call it.
    var displayName: String {
        switch self {
        case .whisper: return "Whisper (whisper.cpp)"
        case .whisperKit: return "WhisperKit (Core ML)"
        case .parakeet: return "Turbo (English/EU)"
        case .appleSpeech: return "Apple Speech"
        }
    }
}
