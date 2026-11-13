import Foundation
import FluidAudio

extension TranscriptionEngine {
    /// `ParakeetEngine`'s model → adapter factory: `spec.path` is a model
    /// folder, already verified by the engine against its manifest digest
    /// (`spec.sha256`) when it's a catalog folder.
    static func parakeetAdapter() -> (ModelSpec) throws -> TranscriptionAdapter {
        { spec in try ParakeetAdapter(folder: URL(fileURLWithPath: spec.path, isDirectory: true), language: spec.language) }
    }
}

/// Parakeet TDT 0.6B v3 on Core ML (Neural Engine), via FluidAudio.
///
/// Loads only from a local folder (`AsrModels.loadLocal`): FluidAudio never
/// touches the network here. Its API is async (an actor); the engine calls
/// adapters synchronously on its own serial queue, so the load and each job
/// block that queue, with a deadline, until they finish (see `wait`).
/// After a deadline, Parakeet is refused until the abandoned work ends.
final class ParakeetAdapter: TranscriptionAdapter {
    private let manager: AsrManager
    private let decoderLayers: Int
    /// FluidAudio's script hint for the chosen language; nil = auto-detect.
    private let language: Language?

    /// Below this FluidAudio rejects a clip (its 0.3 s minimum, plus margin),
    /// so shorter ones are padded with silence. Every clip is padded to the
    /// model's 15 s window anyway, so this costs nothing.
    static let minimumSamples = 16_000

    /// A first load compiles the model for this Mac's Neural Engine (tens of
    /// seconds); allow for slower Macs.
    static let loadTimeout: TimeInterval = 900

    /// Far beyond real time (Parakeet runs ~100x): just a backstop.
    static func jobTimeout(sampleCount: Int) -> TimeInterval {
        max(120, Double(sampleCount) / AudioCapture.sampleRate)
    }

    init(folder: URL, language: String) throws {
        let models: AsrModels
        do {
            models = try Self.wait(timeout: Self.loadTimeout) {
                try await Self.offPool { try AsrModels.loadLocal(from: folder, version: .v3) }
            }
        } catch let busy as BlockingAsync.StillBusy {
            throw busy
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

        let result = try Self.wait(timeout: Self.jobTimeout(sampleCount: audio.count)) { [manager, decoderLayers, language] in
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

    /// Shared by every Parakeet adapter: one engine's abandoned load or job
    /// must hold off the next adapter's too.
    private static let bridge = BlockingAsync.Bridge(name: "Parakeet")

    /// Runs `work` on Swift concurrency's pool and blocks the calling thread
    /// until it finishes or `timeout` passes (`BlockingAsync.TimedOut`; then
    /// `StillBusy` until the abandoned work ends). Can't deadlock: the caller
    /// is the engine's GCD queue (never a cooperative-pool thread or main), and
    /// FluidAudio's ASR path runs on its own actor without hopping to the main
    /// actor.
    private static func wait<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try bridge.run(timeout: timeout, work)
    }

    /// Runs a long synchronous call (the model load) on a GCD thread, so it
    /// doesn't hold a cooperative-pool thread meanwhile.
    private static func offPool<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}
