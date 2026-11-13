import Foundation

/// Where the engine is in its model lifecycle. `failed` (the file exists but
/// wouldn't load — corrupt download or an engine bug) is deliberately distinct
/// from `missing` (no file at all), so the user gets the right fix.
enum TranscriptionStatus: Equatable {
    /// `load()` hasn't been called yet.
    case notLoaded
    case missing
    /// Hashing a model file not checked before (first use; seconds for a
    /// large model). The current model, if any, still takes jobs meanwhile.
    case verifying
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

/// What the engine loads: which engine, its model (a file or directory), the
/// SHA-256 a single-file model must match (nil = unverified: a custom file,
/// a directory, or an OS-managed model), and the language to decode. Build
/// one from the user's settings with `ModelSelection.select`, or for one
/// whisper file with `ModelSpec.file(_:language:)`. Another engine is just
/// another spec, so switching engine is `switchModel(to:)`.
struct ModelSpec: Equatable {
    /// A file or directory; for an OS-managed model, whatever identifies it
    /// to its engine (the engine's `EngineDescriptor.isPresent` decides).
    var path: String
    var sha256: String?
    /// An ISO code ("en", "de", …) or `ModelSpec.autoDetect`.
    var language: String
    var engine: EngineKind = .whisper

    /// How messages name it: the file name, prefixed by the engine unless
    /// it's whisper ("Turbo (English/EU) parakeet-tdt-0.6b-v3").
    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return engine == .whisper ? name : "\(engine.displayName) \(name)"
    }
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
/// `switchModel(to:)` finishes on the old model, the switch then replaces it,
/// and later jobs wait for that.
///
/// `@unchecked Sendable`: the adapter and the `queue`-only state are touched
/// only on `queue`, the rest only under `lock`, and `onStatusChange` is set
/// once before `load()` and only read on main.
final class TranscriptionEngine: @unchecked Sendable {
    private let makeAdapter: (ModelSpec) throws -> TranscriptionAdapter
    private let isPresent: (ModelSpec) -> Bool
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
    /// Set by `prewarm()` until the next job (or `endPrewarm()`): a recording
    /// is under way, so the model must not be unloaded however long it runs.
    private var isHeld = false
    /// Bumped by every job and load; an idle timer only fires if it's unchanged.
    private var activity = 0

    // Under `lock`.
    private let lock = NSLock()
    private var _status: TranscriptionStatus = .notLoaded
    private var _model: ModelSpec
    private var _idleUnloadAfter: TimeInterval?
    private var hasStarted = false

    /// Current status; safe to read from any thread. Stays `.ready` while the
    /// model is unloaded for idleness, since the next job reloads it.
    var status: TranscriptionStatus { lock.withLock { _status } }

    /// The model in use (or being switched to). After a failed switch it is
    /// the previous model again, which the engine went back to.
    var model: ModelSpec { lock.withLock { _model } }

    /// Called on the main thread with each status change the engine reports,
    /// including `.missing` when `load()` finds no model file. Set it before
    /// `load()`.
    var onStatusChange: ((TranscriptionStatus) -> Void)?

    /// `makeAdapter` loads a model into an adapter; it runs off the main
    /// thread, after `isPresent` and `model`'s checksum (if any) check out.
    /// `isPresent` tells a missing model from one that won't load (default: a
    /// file or directory exists at `spec.path`). `idleUnloadAfter` nil keeps
    /// the model loaded. The app uses `TranscriptionEngine.registered(...)`.
    init(model: ModelSpec, idleUnloadAfter: TimeInterval? = nil, verifier: ModelVerifier = .shared,
         isPresent: @escaping (ModelSpec) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter) {
        self._model = model
        self._idleUnloadAfter = idleUnloadAfter
        self.verifier = verifier
        self.isPresent = isPresent
        self.makeAdapter = makeAdapter
    }

    /// Starts loading the model in the background. Status becomes `.missing`
    /// right away if the model isn't installed (`isPresent`), otherwise `.loading` (with
    /// `.verifying` while a not-yet-checked file is hashed) until the load
    /// settles as `.ready` (after the warm-up) or `.failed` (including a
    /// checksum mismatch, in which case the file is never loaded). Call once.
    func load() {
        let spec = lock.withLock { hasStarted = true; return _model }
        guard isPresent(spec) else {
            setStatus(.missing)
            return
        }
        setStatus(.loading)
        queue.async { [self] in load(spec) }
    }

    /// Switches to another model (or language) without a restart. Jobs already
    /// submitted finish on the current model; then the new file is checked
    /// (present, checksum) before the current model is let go, and loaded in
    /// its place. Jobs submitted from now on run on the new one. If the switch
    /// fails, the engine reports `.failed` and goes back to the previous model
    /// (`.ready` again, `model` = the previous one). A no-op if `spec` is
    /// already in use; re-selecting a model that failed retries it. Before
    /// `load()`, it just changes what `load()` will load.
    func switchModel(to spec: ModelSpec) {
        let reload = lock.withLock { () -> Bool in
            let settled = _status == .ready || _status == .loading || _status == .verifying
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

    /// A job is coming (a recording started): reload an idle-unloaded model now
    /// so it's ready when the audio arrives, and keep it loaded — however long
    /// the recording runs — until the next job is submitted or `endPrewarm()`.
    func prewarm() {
        queue.async { [self] in
            reloadIfIdle(warmUp: true)
            isHeld = true
            noteActivity()
        }
    }

    /// The job `prewarm()` expected isn't coming (recording cancelled or
    /// discarded): the idle clock runs again.
    func endPrewarm() {
        queue.async { [self] in
            isHeld = false
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
            transcribe(samples) { continuation.resume(with: $0) }
        }
    }

    /// `transcribe(_:)` for callers that need the job queued before this call
    /// returns. `completion` runs on the engine's queue.
    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        queue.async { [self] in
            reloadIfIdle(warmUp: false)   // the job itself pays the first-run costs
            let result: Result<Transcript, Error>
            if let adapter {
                result = Result { Transcript(segments: try adapter.transcribe(samples: samples)) }
            } else {
                result = .failure(TranscriptionError.modelNotLoaded)
            }
            isHeld = false
            noteActivity()
            completion(result)
        }
    }

    // MARK: - Model lifecycle (on `queue`)

    /// Loads `spec` in place of the current model. The checks that don't need
    /// the RAM (file present, checksum) run first, so a bad pick never costs
    /// the working model; if the load itself fails, the previous model is
    /// loaded again.
    private func load(_ spec: ModelSpec) {
        let previous = loadedSpec ?? idleSpec
        defer { noteActivity() }
        guard isPresent(spec) else {
            return failSwitch(to: spec, .missing, previous: previous, why: "model not found")
        }
        do {
            if let expected = spec.sha256 {
                try verifier.verify(path: spec.path, sha256: expected) { setStatus(.verifying) }
            }
        } catch {
            return failSwitch(to: spec, .failed(reason: error.localizedDescription),
                              previous: previous, why: error.localizedDescription)
        }

        setStatus(.loading)
        unload()   // free the old model's RAM before the new one claims it
        do {
            let loaded = try makeAdapter(spec)
            warmUp(loaded)
            install(loaded, from: spec)
            setStatus(.ready)
        } catch {
            failSwitch(to: spec, .failed(reason: error.localizedDescription),
                       previous: previous, why: error.localizedDescription)
        }
    }

    /// A load of `spec` failed. With no model to go back to, report `status`.
    /// Otherwise go back to `previous` (reloading it if it was already let
    /// go), then report the failure and, right after, `.ready` — so whoever
    /// handles the `.failed` already sees the engine back on `previous`.
    private func failSwitch(to spec: ModelSpec, _ status: TranscriptionStatus, previous: ModelSpec?, why: String) {
        guard let previous else { return setStatus(status) }
        let name = { (s: ModelSpec) in s.displayName }
        lock.withLock { _model = previous }
        if adapter == nil && idleSpec == nil {
            do {
                let restored = try open(previous)
                warmUp(restored)
                install(restored, from: previous)
            } catch {
                return setStatus(.failed(reason: "Couldn't switch to \(name(spec)) (\(why)), "
                                         + "nor reload \(name(previous)): \(error.localizedDescription)"))
            }
        }
        setStatus(.failed(reason: "Couldn't switch to \(name(spec)) (\(why)). Still using \(name(previous))."))
        setStatus(.ready)
    }

    /// Verify (silently — a file already checked hits the cache) and load.
    private func open(_ spec: ModelSpec) throws -> TranscriptionAdapter {
        if let expected = spec.sha256 {
            try verifier.verify(path: spec.path, sha256: expected)
        }
        return try makeAdapter(spec)
    }

    private func install(_ loaded: TranscriptionAdapter, from spec: ModelSpec) {
        adapter = loaded
        loadedSpec = spec
        idleSpec = nil
    }

    private func unload() {
        adapter = nil
        loadedSpec = nil
        idleSpec = nil
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
            install(loaded, from: spec)
            Log.info("Reloaded the idle model in \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
        } catch {
            setStatus(.failed(reason: error.localizedDescription))
        }
    }

    /// Marks activity and, if idle unload is on, schedules an unload for when
    /// this turns out to be the last activity for the idle period. Never while
    /// a recording holds the model.
    private func noteActivity() {
        activity &+= 1
        guard let delay = lock.withLock({ _idleUnloadAfter }) else { return }
        let mark = activity
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.activity == mark, !self.isHeld, self.adapter != nil,
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
