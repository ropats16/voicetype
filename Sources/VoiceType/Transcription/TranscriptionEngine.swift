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

/// What the engine loads: a model file, the SHA-256 it must match (nil = an
/// unverified custom file), and the language to decode. Build one from the
/// user's settings with `ModelSelection.resolve`.
struct ModelSpec: Equatable {
    var path: String
    var sha256: String?
    /// An ISO code ("en", "de", …) or "auto" to detect per job.
    var language: String
}

/// The speech-to-text engine the app talks to. Owns the model lifecycle —
/// checksum check and load off the main thread, a short silent warm-up so the
/// first real job is as fast as later ones, live model switching, and optional
/// unload when idle — and a single serial job queue, so callers never need
/// their own. The concrete engine (whisper.cpp, or a fake in tests) is an
/// adapter behind it.
///
/// Everything that touches the model runs on one serial queue, in order. That
/// one rule gives the switching guarantees: a job submitted before
/// `switchModel(to:)` finishes on the old model, the switch then frees it and
/// loads the new one, and later jobs wait for that load.
///
/// `@unchecked Sendable`: the adapter and the `queue`-only state are touched
/// only on `queue`, the rest only under `lock`, and `onStatusChange` is set
/// once before `load()` and only read on main.
final class TranscriptionEngine: @unchecked Sendable {
    private let makeAdapter: (ModelSpec) throws -> TranscriptionAdapter
    private let verifier: ModelVerifier

    /// Loads, switches, unloads and every job run here, one at a time, in
    /// submission order.
    private let queue = DispatchQueue(label: "com.local.VoiceType.transcription", qos: .userInitiated)

    // `queue`-only.
    private var adapter: TranscriptionAdapter?
    /// What `adapter` was loaded from.
    private var loadedSpec: ModelSpec?
    /// Set while the model is unloaded for idleness: what the next job reloads.
    private var idleSpec: ModelSpec?
    /// Bumped by every job and load; an idle timer only fires if it's unchanged.
    private var activity = 0

    // Under `lock`.
    private let lock = NSLock()
    private var _status: TranscriptionStatus = .notLoaded
    private var _model: ModelSpec
    private var _idleUnloadAfter: TimeInterval?
    private var _isModelLoaded = false
    private var _pendingJobCount = 0
    private var hasStarted = false

    /// Current status; safe to read from any thread. Stays `.ready` while the
    /// model is unloaded for idleness, since the next job reloads it.
    var status: TranscriptionStatus { lock.withLock { _status } }

    /// The model the engine runs (or is switching to).
    var model: ModelSpec { lock.withLock { _model } }

    /// Whether the model is in memory right now (false before a load and
    /// while unloaded for idleness).
    var isModelLoaded: Bool { lock.withLock { _isModelLoaded } }

    /// Jobs submitted and not yet finished, including the running one.
    var pendingJobCount: Int { lock.withLock { _pendingJobCount } }

    /// Called on the main thread with each status change the engine reports,
    /// including `.missing` when `load()` finds no model file. Set it before
    /// `load()`.
    var onStatusChange: ((TranscriptionStatus) -> Void)?

    /// `makeAdapter` loads a model into an adapter; it runs off the main
    /// thread, after `model`'s checksum (if any) checks out. `idleUnloadAfter`
    /// nil keeps the model loaded. The app uses `TranscriptionEngine.whisper(...)`.
    init(model: ModelSpec, idleUnloadAfter: TimeInterval? = nil, verifier: ModelVerifier = .shared,
         makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter) {
        self._model = model
        self._idleUnloadAfter = idleUnloadAfter
        self.verifier = verifier
        self.makeAdapter = makeAdapter
    }

    /// A fixed, unverified model file, kept loaded.
    convenience init(modelPath: String, makeAdapter: @escaping (String) throws -> TranscriptionAdapter) {
        self.init(model: ModelSpec(path: modelPath, sha256: nil, language: "en"),
                  makeAdapter: { try makeAdapter($0.path) })
    }

    /// Starts loading the model in the background. Status becomes `.missing`
    /// right away if there's no model file, otherwise `.loading` until the load
    /// settles as `.ready` (after the warm-up) or `.failed` (including a
    /// checksum mismatch, in which case the file is never loaded). Call once.
    func load() {
        let spec = lock.withLock { hasStarted = true; return _model }
        guard FileManager.default.fileExists(atPath: spec.path) else {
            setStatus(.missing)
            return
        }
        setStatus(.loading)
        queue.async { [self] in load(spec) }
    }

    /// Switches to another model (or language) without a restart. Jobs already
    /// submitted finish on the current model; the switch then frees it and
    /// loads `spec` (status `.loading`, then `.ready`, `.missing` or
    /// `.failed`), and jobs submitted from now on run on the new one. A no-op
    /// if `spec` is already loaded; re-selecting a model that failed retries
    /// it. Before `load()`, it just changes what `load()` will load.
    func switchModel(to spec: ModelSpec) {
        let reload = lock.withLock { () -> Bool in
            let settled = _status == .ready || _status == .loading
            guard spec != _model || !settled else { return false }
            _model = spec
            return hasStarted
        }
        guard reload else { return }
        queue.async { [self] in
            // A later switch supersedes this one; skip the wasted load.
            guard spec == model else { return }
            load(spec)
        }
    }

    /// Unload the model after this long without a job, or never (nil). Takes
    /// effect now: turning it off reloads an unloaded model in the background.
    func setIdleUnload(after delay: TimeInterval?) {
        lock.withLock { _idleUnloadAfter = delay }
        queue.async { [self] in
            if delay == nil { reloadIfIdle(warmUp: true) }
            noteActivity()   // restart the idle clock with the new delay
        }
    }

    /// A job is likely soon (e.g. recording started): reload an idle-unloaded
    /// model now so it's ready when the audio arrives. Cheap when loaded.
    func prewarm() {
        queue.async { [self] in
            reloadIfIdle(warmUp: true)
            noteActivity()
        }
    }

    /// Transcribes 16 kHz mono Float32 PCM. Jobs run one at a time in
    /// submission order, never on the calling thread. A job submitted while
    /// the model is loading or switching waits for the load; one arriving
    /// while the model is unloaded for idleness reloads it first. If no model
    /// is loaded when its turn comes (missing, failed, or `load()` never
    /// called) it throws `TranscriptionError.modelNotLoaded`.
    func transcribe(_ samples: [Float]) async throws -> Transcript {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { _pendingJobCount += 1 }
            queue.async { [self] in
                reloadIfIdle(warmUp: false)   // the job itself pays the first-run costs
                let result: Result<Transcript, Error>
                if let adapter {
                    result = Result { Transcript(segments: try adapter.transcribe(samples: samples)) }
                } else {
                    result = .failure(TranscriptionError.modelNotLoaded)
                }
                lock.withLock { _pendingJobCount -= 1 }
                noteActivity()
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Model lifecycle (on `queue`)

    /// Frees the current model, then verifies, loads and warms up `spec`.
    private func load(_ spec: ModelSpec) {
        unload()
        guard FileManager.default.fileExists(atPath: spec.path) else {
            setStatus(.missing)
            return
        }
        setStatus(.loading)
        do {
            let loaded = try open(spec)
            warmUp(loaded)
            resident(loaded, spec)
            setStatus(.ready)
        } catch {
            setStatus(.failed(reason: error.localizedDescription))
        }
        noteActivity()
    }

    /// The checksum gate: a file that doesn't match is never handed to the adapter.
    private func open(_ spec: ModelSpec) throws -> TranscriptionAdapter {
        if let expected = spec.sha256 {
            try verifier.verify(path: spec.path, sha256: expected)
        }
        return try makeAdapter(spec)
    }

    private func resident(_ loaded: TranscriptionAdapter, _ spec: ModelSpec) {
        adapter = loaded
        loadedSpec = spec
        idleSpec = nil
        lock.withLock { _isModelLoaded = true }
    }

    private func unload() {
        adapter = nil
        loadedSpec = nil
        idleSpec = nil
        lock.withLock { _isModelLoaded = false }
    }

    /// Reloads a model unloaded for idleness. Status stays `.ready` unless the
    /// reload fails (e.g. the file was deleted or replaced).
    private func reloadIfIdle(warmUp shouldWarmUp: Bool) {
        guard adapter == nil, let spec = idleSpec else { return }
        idleSpec = nil
        let start = Date()
        do {
            let loaded = try open(spec)
            if shouldWarmUp { warmUp(loaded) }
            resident(loaded, spec)
            Log.info("Reloaded the idle model in \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
        } catch {
            setStatus(.failed(reason: error.localizedDescription))
        }
    }

    /// Marks activity and, if idle unload is on, schedules an unload for when
    /// this turns out to be the last activity for the idle period.
    private func noteActivity() {
        activity &+= 1
        guard let delay = lock.withLock({ _idleUnloadAfter }) else { return }
        let mark = activity
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.activity == mark, self.adapter != nil,
                  self.lock.withLock({ self._idleUnloadAfter }) != nil else { return }
            let spec = self.loadedSpec
            self.unload()
            self.idleSpec = spec
            Log.info("Unloaded the model after \(Int(delay))s idle; the next dictation reloads it.")
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

    /// Records and reports a status change; repeats are dropped.
    private func setStatus(_ new: TranscriptionStatus) {
        let changed = lock.withLock { () -> Bool in
            guard _status != new else { return false }
            _status = new
            return true
        }
        guard changed else { return }
        // Weak: a pending callback mustn't keep the engine (and its model) alive.
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(new) }
    }
}
