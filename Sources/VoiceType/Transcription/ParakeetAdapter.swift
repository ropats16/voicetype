import Foundation
import FluidAudio

extension TranscriptionEngine {
    /// An engine on Parakeet TDT v3 (Core ML, via FluidAudio) behind the
    /// engine's load, warm-up, job queue and live model switching. `model.path`
    /// is a model folder (`ParakeetModel.folder()`) and `model.sha256` nil:
    /// the adapter verifies a catalog folder file by file itself.
    static func parakeet(model: ModelSpec, idleUnloadAfter: TimeInterval? = nil) -> TranscriptionEngine {
        TranscriptionEngine(model: model, idleUnloadAfter: idleUnloadAfter, makeAdapter: parakeetAdapter())
    }

    /// The adapter factory `parakeet(...)` uses, for callers (the bench) that
    /// build their own engine around it. A folder named like a catalog model
    /// (`ParakeetCatalog.model(forFolder:)`) must match its pinned files
    /// (checked with `verifier`, whose cache makes later loads cheap); any
    /// other folder loads unverified, like a custom whisper file.
    static func parakeetAdapter(verifier: ModelVerifier = .shared) -> (ModelSpec) throws -> TranscriptionAdapter {
        { spec in
            let folder = URL(fileURLWithPath: spec.path, isDirectory: true)
            if let model = ParakeetCatalog.model(forFolder: spec.path) {
                let start = Date()
                var hashed = false
                try model.verify(folder: folder, verifier: verifier) { hashed = true }
                if hashed {
                    Log.info("Checksummed \(model.id) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s.")
                }
            }
            return try ParakeetAdapter(folder: folder, language: spec.language)
        }
    }
}

/// Parakeet TDT 0.6B v3 on Core ML (Neural Engine), via FluidAudio.
///
/// Loads only from a local folder (`AsrModels.loadLocal`): FluidAudio never
/// touches the network here. Its API is async (an actor); the engine calls
/// adapters synchronously on its own serial queue, so each job blocks that
/// queue until the decode finishes (see `wait`).
final class ParakeetAdapter: TranscriptionAdapter {
    private let manager: AsrManager
    private let decoderLayers: Int
    /// FluidAudio's script hint for the chosen language; nil = auto-detect.
    private let language: Language?

    /// Below this FluidAudio rejects a clip (its 0.3 s minimum, plus margin),
    /// so shorter ones are padded with silence. Every clip is padded to the
    /// model's 15 s window anyway, so this costs nothing.
    static let minimumSamples = 16_000

    init(folder: URL, language: String) throws {
        let models: AsrModels
        do {
            models = try AsrModels.loadLocal(from: folder, version: .v3)
        } catch {
            Log.error("Parakeet model failed to load from \(folder.path): \(error.localizedDescription)")
            throw TranscriptionError.modelLoadFailed(path: folder.path)
        }
        manager = AsrManager(config: .default, models: models)
        decoderLayers = models.version.decoderLayers
        self.language = language == ModelSpec.autoDetect ? nil : Language(rawValue: language.lowercased())
    }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        guard !samples.isEmpty else { return [] }
        let duration = Double(samples.count) / AudioCapture.sampleRate
        let audio = samples.count >= Self.minimumSamples
            ? samples : samples + [Float](repeating: 0, count: Self.minimumSamples - samples.count)

        let result = try Self.wait { [manager, decoderLayers, language] in
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            return try await manager.transcribe(audio, decoderState: &state, language: language)
        }

        let tokens = (result.tokenTimings ?? []).map {
            ParakeetToken(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if tokens.isEmpty && !text.isEmpty {
            // No timings (not expected from TDT): one segment for the clip.
            return [Transcript.Segment(text: " " + text, start: 0, end: duration)]
        }
        return ParakeetSegmenter.segments(from: tokens, clipDuration: duration)
    }

    /// Runs `work` on Swift concurrency's pool and blocks the calling thread
    /// until it finishes. Can't deadlock: the caller is the engine's GCD
    /// queue (never a cooperative-pool thread or main), and FluidAudio's ASR
    /// path runs on its own actor without hopping to the main actor.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Hands a result from the detached task back to the waiting thread; the
/// semaphore orders the write before the read.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
