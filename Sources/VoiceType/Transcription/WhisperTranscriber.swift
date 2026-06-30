import Foundation
import CWhisper

/// Swift wrapper over the whisper.cpp C API, Metal-accelerated.
///
/// A whisper context is **not** thread-safe, so transcription must be
/// serialized. `DictationController` only ever calls `transcribe` from a single
/// serial queue, so no internal locking is needed here.
final class WhisperTranscriber: Transcriber {
    private let ctx: OpaquePointer
    private let language: String
    private let threads: Int32

    init(modelPath: String, language: String, threads: Int) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriptionError.modelNotFound(path: modelPath)
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true        // Metal on Apple Silicon
        cparams.flash_attn = true     // recommended with Metal

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriptionError.modelLoadFailed(path: modelPath)
        }
        self.ctx = ctx
        self.language = language

        let hw = ProcessInfo.processInfo.activeProcessorCount
        self.threads = Int32(threads > 0 ? threads : max(1, min(hw, 8)))
    }

    deinit {
        whisper_free(ctx)
    }

    func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // `language` must stay valid for the duration of whisper_full (sync call).
        let langC = strdup(language)
        defer { free(langC) }
        params.language = UnsafePointer(langC)
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_context = true
        params.single_segment = false

        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { throw TranscriptionError.inferenceFailed }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text
    }
}
