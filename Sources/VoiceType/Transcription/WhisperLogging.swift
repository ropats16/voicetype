import Foundation
import CWhisper

/// Silences whisper.cpp and ggml, which by default print dozens of lines to
/// stderr on every model load (and VAD/Metal chatter on every job). Their
/// warnings and errors go to `Log.debug` (the unified log; also stderr in
/// debug builds); everything else is dropped. Our own `Log` is untouched.
enum WhisperLogging {
    /// Installs the sink (whisper's setter also covers ggml's). Idempotent;
    /// call before the first whisper context is created.
    static func install() { _ = installed }

    static var isInstalled: Bool { installed }

    private static let installed: Bool = {
        whisper_log_set({ level, text, _ in
            guard WhisperLogging.forwards(level), let text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { Log.debug("whisper: \(line)") }
        }, nil)
        return true
    }()

    /// Whether a whisper/ggml message at `level` reaches `Log.debug`.
    static func forwards(_ level: ggml_log_level) -> Bool {
        level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR
    }
}
