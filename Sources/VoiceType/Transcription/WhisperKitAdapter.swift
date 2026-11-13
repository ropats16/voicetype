import Foundation
import WhisperKit

extension TranscriptionEngine {
    /// The adapter factory for WhisperKit (Core ML: encoder and decoder on the
    /// Neural Engine). `spec.path` is a local model folder (a
    /// `WhisperKitCatalog` download, or any folder of WhisperKit `.mlmodelc`s
    /// plus `tokenizer.json`); `spec.language` an ISO code or
    /// `ModelSpec.autoDetect`. Nothing is ever downloaded: a folder without
    /// its tokenizer fails to load rather than fetch one.
    ///
    /// The first load of a model on a Mac is slow (Core ML specializes it for
    /// this chip's Neural Engine, seconds to minutes for large models; the OS
    /// caches the result), and runs inside the factory, so the engine reports
    /// `.loading` meanwhile.
    static func whisperKitAdapter() -> (ModelSpec) throws -> TranscriptionAdapter {
        { spec in try WhisperKitAdapter(modelFolder: spec.path, language: spec.language) }
    }
}

/// `TranscriptionAdapter` over WhisperKit. WhisperKit is async; the adapter
/// protocol is sync and only ever called on the engine's serial background
/// queue, so each call blocks that queue on a detached task. WhisperKit never
/// hops to the main actor, so this can't deadlock — but it must not be called
/// on main (asserted).
final class WhisperKitAdapter: TranscriptionAdapter {
    private let pipe: WhisperKit
    private let options: DecodingOptions

    init(modelFolder: String, language: String) throws {
        let folder = URL(fileURLWithPath: modelFolder, isDirectory: true)
        // WhisperKit falls back to downloading a tokenizer it can't find locally.
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) else {
            throw TranscriptionError.modelLoadFailed(path: modelFolder)
        }
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                      verbose: false, logLevel: .none, load: true, download: false)
        let start = Date()
        do {
            pipe = try Self.blocking { try await WhisperKit(config) }
        } catch {
            Log.error("WhisperKit failed to load \(folder.lastPathComponent): \(error)")
            throw TranscriptionError.modelLoadFailed(path: modelFolder)
        }
        Log.info("WhisperKit loaded \(folder.lastPathComponent) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")

        let lang = language == ModelSpec.autoDetect ? nil : language
        options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: lang,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false   // segments carry start/end times
        )
    }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        guard !samples.isEmpty else { return [] }
        var options = options
        options.windowClipTime = Self.windowClipTime(forSampleCount: samples.count)
        let results: [TranscriptionResult]
        do {
            results = try Self.blocking { [pipe, options] in
                try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            }
        } catch {
            Log.error("WhisperKit transcription failed: \(error)")
            throw TranscriptionError.inferenceFailed
        }
        let raw = results.flatMap(\.segments).map {
            Transcript.Segment(text: $0.text, start: TimeInterval($0.start), end: TimeInterval($0.end))
        }
        return Self.normalize(raw)
    }

    /// The tail, in seconds, in which WhisperKit won't start a new window (a
    /// guard against hallucinating on a sliver of audio). Its 1 s default
    /// would leave a clip of a second or less undecoded — a quick "Yes.", or
    /// the engine's warm-up — so short clips get half their length instead.
    static func windowClipTime(forSampleCount count: Int) -> Float {
        min(1.0, Float(count) / Float(WhisperKit.sampleRate) / 2)
    }

    /// WhisperKit segments as the app's: special tokens (`<|…|>`) and
    /// non-speech tags removed, empty segments dropped, and each text trimmed
    /// to one leading space — how whisper.cpp's segments read, so
    /// `Transcript.text` joins them the same way. Times are kept.
    static func normalize(_ raw: [Transcript.Segment]) -> [Transcript.Segment] {
        let spoken = raw.compactMap { segment -> Transcript.Segment? in
            let text = segment.text
                .replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Transcript.Segment(text: " " + text, start: segment.start, end: segment.end)
        }
        return NonSpeechFilter.filter(spoken)
    }

    /// Runs `work` on the concurrency pool and blocks this (non-main, non-pool)
    /// thread until it finishes.
    private static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    /// Hands a result across the semaphore; written once before `signal`,
    /// read once after `wait`.
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
