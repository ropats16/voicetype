import Foundation

/// Where the engine is in its model lifecycle. `failed` (the file exists but
/// wouldn't load — corrupt download or an engine bug) is deliberately distinct
/// from `missing` (no file at all), so the user gets the right fix.
enum TranscriptionStatus: Equatable {
    /// `load()` hasn't been called yet.
    case notLoaded
    case missing
    case loading
    case ready
    case failed(reason: String)
}

/// Errors the engine (and its adapters) surface to callers.
enum TranscriptionError: LocalizedError {
    case modelLoadFailed(path: String)
    case modelNotLoaded
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load the transcription model at \(path)."
        case .modelNotLoaded:
            return "No transcription model is loaded."
        case .inferenceFailed:
            return "Transcription failed."
        }
    }
}

/// The result of one transcription job: timestamped segments in order.
struct Transcript: Equatable {
    struct Segment: Equatable {
        let text: String
        /// Seconds from the start of the submitted audio.
        let start: TimeInterval
        let end: TimeInterval
    }

    let segments: [Segment]

    /// All segment text joined, as spoken. Untrimmed: whisper.cpp segments carry
    /// their own leading spaces.
    var text: String { segments.map(\.text).joined() }
}

/// The speech-to-text engine the app talks to. Owns the model lifecycle (load
/// off the main thread, then a short silent warm-up so the first real job is as
/// fast as later ones) and a single serial job queue, so callers never need
/// their own. The concrete engine (whisper.cpp, or a fake in tests) is an
/// adapter behind it.
///
/// `@unchecked Sendable`: the adapter is touched only on `queue`, `status` only
/// under `lock`, and `onStatusChange` is set once before `load()` and only read
/// on main.
final class TranscriptionEngine: @unchecked Sendable {
    private let modelPath: String
    private let makeAdapter: (String) throws -> TranscriptionAdapter

    /// Load and every job run here, one at a time, in submission order.
    private let queue = DispatchQueue(label: "com.local.VoiceType.transcription", qos: .userInitiated)
    /// Touched only on `queue`.
    private var adapter: TranscriptionAdapter?

    private let lock = NSLock()
    private var _status: TranscriptionStatus = .notLoaded

    /// Current status; safe to read from any thread.
    var status: TranscriptionStatus { lock.withLock { _status } }

    /// Called on the main thread with each status the engine reports, including
    /// `.missing` when `load()` finds no model file. Set it before `load()`.
    var onStatusChange: ((TranscriptionStatus) -> Void)?

    /// `makeAdapter` loads the model at the given path into an adapter; it runs
    /// off the main thread. The app uses `TranscriptionEngine.whisper(...)`.
    init(modelPath: String, makeAdapter: @escaping (String) throws -> TranscriptionAdapter) {
        self.modelPath = modelPath
        self.makeAdapter = makeAdapter
    }

    /// Starts loading the model in the background. Status becomes `.missing`
    /// right away if there's no model file, otherwise `.loading` until the load
    /// settles as `.ready` (after the warm-up) or `.failed`. Call once.
    func load() {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            setStatus(.missing)
            return
        }
        setStatus(.loading)
        queue.async { [self] in
            do {
                let loaded = try makeAdapter(modelPath)
                warmUp(loaded)
                adapter = loaded
                setStatus(.ready)
            } catch {
                setStatus(.failed(reason: error.localizedDescription))
            }
        }
    }

    /// One short silent inference so the engine's first-run costs (GPU pipeline
    /// compilation, buffer allocation) are paid at load, not on the first
    /// dictation. A failure here is logged, not fatal: the model did load.
    private func warmUp(_ adapter: TranscriptionAdapter) {
        let start = Date()
        do {
            _ = try adapter.transcribe(samples: [Float](repeating: 0, count: Self.warmUpSampleCount))
            Log.info("Transcription engine warmed up in \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
        } catch {
            Log.error("Transcription warm-up failed: \(error.localizedDescription)")
        }
    }

    /// 1 s at 16 kHz.
    private static let warmUpSampleCount = 16_000

    /// Transcribes 16 kHz mono Float32 PCM. Jobs run one at a time in
    /// submission order, never on the calling thread. A job submitted while
    /// the model is still loading waits for the load; if no model is loaded
    /// when its turn comes (missing, failed, or `load()` never called) it
    /// throws `TranscriptionError.modelNotLoaded`.
    func transcribe(_ samples: [Float]) async throws -> Transcript {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let adapter else {
                    continuation.resume(throwing: TranscriptionError.modelNotLoaded)
                    return
                }
                continuation.resume(with: Result {
                    Transcript(segments: try adapter.transcribe(samples: samples))
                })
            }
        }
    }

    private func setStatus(_ new: TranscriptionStatus) {
        lock.withLock { _status = new }
        // Weak: a pending callback mustn't keep the engine (and its model) alive.
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(new) }
    }
}
