import Foundation
import CWhisper

extension TranscriptionEngine {
    /// The app's engine: whisper.cpp (Metal-accelerated) behind the engine's
    /// checksum check, load, warm-up, job queue and live model switching; the
    /// model is unloaded after `idleUnloadAfter` idle seconds (nil = keep it).
    static func whisper(model: ModelSpec, threads: Int, tuning: WhisperTuning = .default,
                        idleUnloadAfter: TimeInterval? = nil) -> TranscriptionEngine {
        TranscriptionEngine(model: model, idleUnloadAfter: idleUnloadAfter,
                            makeAdapter: whisperAdapter(threads: threads, tuning: tuning))
    }

    /// The adapter factory `whisper(...)` uses (file and language come from
    /// the spec), for callers (the bench) that build their own engine around it.
    static func whisperAdapter(threads: Int, tuning: WhisperTuning = .default)
        -> (ModelSpec) throws -> TranscriptionAdapter {
        { spec in try WhisperAdapter(modelPath: spec.path, language: spec.language, threads: threads, tuning: tuning) }
    }
}

/// Swift wrapper over the whisper.cpp C API, Metal-accelerated.
///
/// A whisper context is **not** thread-safe, so transcription must be
/// serialized. `TranscriptionEngine` only ever calls it from its own serial
/// queue, so no internal locking is needed here.
final class WhisperAdapter: TranscriptionAdapter {
    private let ctx: OpaquePointer
    private let threads: Int32
    private let tuning: WhisperTuning
    /// C strings whisper_full reads; owned for the adapter's lifetime.
    private let languageC: UnsafeMutablePointer<CChar>
    private let vadModelPathC: UnsafeMutablePointer<CChar>?

    init(modelPath: String, language: String, threads: Int, tuning: WhisperTuning = .default) throws {
        WhisperLogging.install()   // before the first context, so its load is silent too
        if let vadPath = tuning.vad.modelPath, !FileManager.default.fileExists(atPath: vadPath) {
            throw TranscriptionError.modelLoadFailed(path: vadPath)
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true        // Metal on Apple Silicon
        cparams.flash_attn = true     // recommended with Metal

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriptionError.modelLoadFailed(path: modelPath)
        }
        self.ctx = ctx
        self.tuning = tuning
        self.languageC = strdup(language)
        self.vadModelPathC = tuning.vad.modelPath.map { strdup($0) }

        let hw = ProcessInfo.processInfo.activeProcessorCount
        self.threads = Int32(threads > 0 ? threads : max(1, min(hw, 8)))
    }

    deinit {
        whisper_free(ctx)
        free(languageC)
        free(vadModelPathC)
    }

    /// The `whisper_full` params for one job of `sampleCount` samples: the
    /// app's fixed choices plus `tuning`. `language` and `vadModelPath` must
    /// outlive the `whisper_full` call (nil path = VAD off).
    static func fullParams(tuning: WhisperTuning, language: UnsafePointer<CChar>?,
                           vadModelPath: UnsafePointer<CChar>?, threads: Int32,
                           sampleCount: Int) -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = language
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = false  // segments carry start/end times
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_context = true
        params.single_segment = false

        params.suppress_nst = tuning.suppressNonSpeech
        // With VAD on, whisper encodes only the speech, so this (sized from
        // the whole clip) is an upper bound — still safe.
        params.audio_ctx = tuning.audioContext(forSampleCount: sampleCount)
        params.temperature = 0
        params.temperature_inc = tuning.temperatureIncrement
        params.vad = vadModelPath != nil
        params.vad_model_path = vadModelPath
        return params
    }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        guard !samples.isEmpty else { return [] }

        let params = Self.fullParams(tuning: tuning, language: languageC, vadModelPath: vadModelPathC,
                                     threads: threads, sampleCount: samples.count)
        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { throw TranscriptionError.inferenceFailed }

        // whisper.cpp reports segment times in 10 ms ticks.
        let segments = (0..<whisper_full_n_segments(ctx)).map { i in
            Transcript.Segment(
                text: whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? "",
                start: TimeInterval(whisper_full_get_segment_t0(ctx, i)) / 100,
                end: TimeInterval(whisper_full_get_segment_t1(ctx, i)) / 100
            )
        }
        return NonSpeechFilter.filter(segments)
    }
}
