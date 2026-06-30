import Foundation

/// Abstracts the speech engine so the dictation flow doesn't depend on
/// whisper.cpp directly. The concrete `WhisperTranscriber` conforms.
protocol Transcriber: AnyObject {
    /// Transcribe 16 kHz mono Float32 PCM into punctuated text. Runs
    /// synchronously; callers invoke it off the main thread.
    func transcribe(samples: [Float]) throws -> String
}

enum TranscriptionError: LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(path: String)
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file not found at \(path). Run `make setup` to download it."
        case .modelLoadFailed(let path):
            return "Failed to load the Whisper model at \(path)."
        case .inferenceFailed:
            return "Transcription failed."
        }
    }
}
