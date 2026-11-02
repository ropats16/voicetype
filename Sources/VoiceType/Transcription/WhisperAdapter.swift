import Foundation
import CWhisper

extension TranscriptionEngine {
    /// The app's engine: whisper.cpp (Metal-accelerated) behind the engine's
    /// load, warm-up and job queue.
    static func whisper(modelPath: String, language: String, threads: Int) -> TranscriptionEngine {
        TranscriptionEngine(modelPath: modelPath) { path in
            try WhisperAdapter(modelPath: path, language: language, threads: threads)
        }
    }
}

/// Swift wrapper over the whisper.cpp C API, Metal-accelerated.
///
/// A whisper context is **not** thread-safe, so transcription must be
/// serialized. `TranscriptionEngine` only ever calls it from its own serial
/// queue, so no internal locking is needed here.
final class WhisperAdapter: TranscriptionAdapter {
    private let ctx: OpaquePointer
    private let language: String
    private let threads: Int32

    init(modelPath: String, language: String, threads: Int) throws {
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

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // `language` must stay valid for the duration of whisper_full (sync call).
        let langC = strdup(language)
        defer { free(langC) }
        params.language = UnsafePointer(langC)
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = false  // segments carry start/end times
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

        // whisper.cpp reports segment times in 10 ms ticks.
        return (0..<whisper_full_n_segments(ctx)).map { i in
            Transcript.Segment(
                text: whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? "",
                start: TimeInterval(whisper_full_get_segment_t0(ctx, i)) / 100,
                end: TimeInterval(whisper_full_get_segment_t1(ctx, i)) / 100
            )
        }
    }
}
