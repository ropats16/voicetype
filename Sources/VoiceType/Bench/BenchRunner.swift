import Foundation

/// A speech engine the bench can run: an id for the report, and what the app
/// itself loads it with — its presence check, how `--model` becomes a
/// `ModelSpec`, and the model → adapter factory `TranscriptionEngine` takes.
/// Built from the app's `EngineRegistry`, so registering an engine there is
/// all it takes to bench it.
struct BenchEngine {
    /// The engine settings the app takes from `Config`.
    struct Options: Equatable {
        let language: String
        /// 0 = the engine's own default.
        let threads: Int
        /// whisper.cpp knobs (`--suppress-nst`, `--audio-ctx`, …); other engines ignore them.
        var whisper: WhisperTuning = .default
    }

    let id: String
    /// Whether a model is installed (`EngineDescriptor.isPresent`).
    var isPresent: (ModelSpec) -> Bool
    /// `--model` and `--language` → the spec to load
    /// (`EngineDescriptor.spec(forModelArgument:language:)`).
    var modelSpec: (_ argument: String, _ language: String) -> ModelSpec
    let makeAdapter: (ModelSpec) throws -> TranscriptionAdapter

    /// A bench-only engine (tests); `modelSpec` takes the argument as an
    /// unverified path.
    init(id: String, isPresent: @escaping (ModelSpec) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         modelSpec: @escaping (String, String) -> ModelSpec = { ModelSpec(path: $0, sha256: nil, language: $1) },
         makeAdapter: @escaping (ModelSpec) throws -> TranscriptionAdapter) {
        self.id = id
        self.isPresent = isPresent
        self.modelSpec = modelSpec
        self.makeAdapter = makeAdapter
    }

    /// A registered engine, as the app runs it.
    init(_ descriptor: any EngineDescriptor, _ options: Options) {
        self.init(id: descriptor.kind.rawValue, isPresent: descriptor.isPresent,
                  modelSpec: descriptor.spec(forModelArgument:language:),
                  makeAdapter: descriptor.makeAdapter(EngineOptions(threads: options.threads, whisper: options.whisper)))
    }

    /// Every engine `--bench --engine <id>` accepts here: those registered
    /// in `engines` that this Mac can run.
    static func all(_ options: Options, engines: EngineRegistry = .shared,
                    environment: EngineEnvironment = .current) -> [BenchEngine] {
        engines.available(in: environment).compactMap { engines.descriptor(for: $0) }.map { BenchEngine($0, options) }
    }

    /// The engine `id` names, or an error saying why it can't be benched
    /// (unknown id, not in this build, or not on this Mac).
    static func resolve(_ id: String, _ options: Options, engines: EngineRegistry = .shared,
                        environment: EngineEnvironment = .current) throws -> BenchEngine {
        if case .unavailable(let reason) = engines.availability(ofID: id, in: environment) {
            let known = EngineKind(rawValue: id) == nil
                ? " (engines: \(EngineKind.allCases.map(\.rawValue).joined(separator: ", ")))" : ""
            throw BenchError.engineUnavailable("can't bench \(id): \(reason)\(known)")
        }
        return BenchEngine(engines.descriptor(for: EngineKind(rawValue: id)!)!, options)
    }

    static func named(_ id: String, _ options: Options) -> BenchEngine? { try? resolve(id, options) }
}

/// One fixture, decoded to 16 kHz mono.
struct BenchClip {
    enum Kind: String, Codable {
        /// A dictation-length clip, timed for latency.
        case short
        /// Minutes of audio, timed for real-time factor.
        case long
    }

    let id: String
    let kind: Kind
    let reference: String
    let samples: [Float]

    var audioSeconds: Double { Double(samples.count) / AudioCapture.sampleRate }
}

extension Array where Element == BenchClip {
    func of(_ kind: BenchClip.Kind) -> [BenchClip] { filter { $0.kind == kind } }
}

enum BenchError: LocalizedError {
    case modelMissing(path: String)
    case loadFailed(reason: String)
    /// `--engine` names one this build or Mac can't run; the message says why.
    case engineUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "model not found at \(path)"
        case .loadFailed(let reason): return "model failed to load: \(reason)"
        case .engineUnavailable(let message): return message
        }
    }
}

/// Runs one engine over the fixtures, entirely through `TranscriptionEngine`:
/// loads it (timing the adapter's own load apart from the engine's warm-up),
/// transcribes each short clip `shortRuns` times for latency and each long
/// clip once for real-time factor, scores every transcript's WER, and tracks
/// the process's memory footprint throughout.
struct BenchRunner {
    let engine: BenchEngine
    /// The model file and language (`ModelSpec.file(_:language:)`).
    let model: ModelSpec
    /// Passes over the short clips (≥ 1); more runs steady the percentiles.
    var shortRuns: Int

    /// Monotonic seconds; injectable so tests can fake the passage of time.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The process's memory now; nil if it can't be read.
    var memory: () -> MemorySnapshot? = MemorySnapshot.current
    /// How often memory is sampled while jobs run (it's also sampled between them).
    var memorySampleInterval: TimeInterval = 0.005

    /// Checks a catalog model's checksum before the timed load, so a first
    /// run's hashing doesn't count as load time.
    var verifier: ModelVerifier = .shared

    init(engine: BenchEngine, model: ModelSpec, shortRuns: Int) {
        self.engine = engine
        self.model = model
        self.shortRuns = shortRuns
    }

    func run(_ clips: [BenchClip]) async throws -> BenchResults {
        let baseline = memory()
        let peak = PeakSampler(memory: memory)
        peak.start(every: memorySampleInterval)
        defer { peak.stop() }

        // Wrap the factory and adapter so the bench sees exactly what the
        // engine does: how long the factory took, and when its warm-up ran.
        let timing = LoadTiming()
        if let expected = model.sha256, FileManager.default.fileExists(atPath: model.path) {
            do { try verifier.verify(path: model.path, sha256: expected) } catch {
                throw BenchError.loadFailed(reason: error.localizedDescription)
            }
        }
        let transcriptionEngine = TranscriptionEngine(model: model, verifier: verifier,
                                                      isPresent: engine.isPresent) { [clock, make = engine.makeAdapter] spec in
            let start = clock()
            let inner = try make(spec)
            let adapter = TimedAdapter(inner, clock: clock)
            timing.set(adapterSeconds: clock() - start, adapter: adapter)
            return adapter
        }

        let loadStart = clock()
        transcriptionEngine.load()
        while [.notLoaded, .loading, .verifying].contains(transcriptionEngine.status) { try await Task.sleep(nanoseconds: 1_000_000) }
        switch transcriptionEngine.status {
        case .ready: break
        case .missing: throw BenchError.modelMissing(path: model.path)
        case .failed(let reason): throw BenchError.loadFailed(reason: reason)
        case .notLoaded, .loading, .verifying: throw BenchError.loadFailed(reason: "\(engine.id) never finished loading")
        }
        // The warm-up is the adapter's first call; the engine reports ready
        // right after it, so the load ends when it does (not when we polled).
        let (adapterSeconds, warmUp) = timing.get()
        let load = BenchResults.Load(adapterSeconds: adapterSeconds,
                                     warmUpSeconds: warmUp?.seconds ?? 0,
                                     totalSeconds: (warmUp?.end ?? clock()) - loadStart)
        peak.sample()
        let loaded = memory()

        let short = try await runShort(clips.of(.short), on: transcriptionEngine, peak: peak)
        let long = try await runLong(clips.of(.long), on: transcriptionEngine, peak: peak)

        let end = memory()
        var memoryResult: BenchResults.Memory?
        if let baseline, let loaded, let end, let peakBytes = peak.max {
            memoryResult = .init(baselineBytes: baseline.footprintBytes, loadedBytes: loaded.footprintBytes,
                                 peakBytes: peakBytes, lifetimePeakBytes: end.lifetimePeakBytes)
        }
        return BenchResults(load: load, memory: memoryResult, short: short, long: long)
    }

    /// One timed job; memory is sampled after the clock stops.
    private func timedTranscribe(_ clip: BenchClip, on engine: TranscriptionEngine,
                                 peak: PeakSampler) async throws -> (text: String, seconds: TimeInterval) {
        let start = clock()
        let text = try await engine.transcribe(clip.samples).text
        let seconds = clock() - start
        peak.sample()
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), seconds)
    }

    private func runShort(_ clips: [BenchClip], on engine: TranscriptionEngine,
                          peak: PeakSampler) async throws -> BenchResults.Short {
        var latencies = [[Double]](repeating: [], count: clips.count)
        var hypotheses = [String](repeating: "", count: clips.count)
        // Round-robin, so slow drift (thermals, background load) spreads over
        // every clip instead of landing on one.
        for run in 0..<shortRuns {
            for (i, clip) in clips.enumerated() {
                let job = try await timedTranscribe(clip, on: engine, peak: peak)
                latencies[i].append(job.seconds)
                if run == 0 { hypotheses[i] = job.text }
            }
        }
        let results = clips.enumerated().map { i, clip in
            BenchResults.ShortClip(id: clip.id, audioSeconds: clip.audioSeconds,
                                   latenciesSeconds: latencies[i],
                                   medianLatencySeconds: BenchStats.percentile(latencies[i], 50) ?? 0,
                                   transcript: .init(reference: clip.reference, hypothesis: hypotheses[i]))
        }
        return BenchResults.Short(clips: results, latency: BenchStats.LatencySummary(latencies.flatMap { $0 }),
                                  wer: WordErrorRate.total(results.map(\.transcript.wer)))
    }

    private func runLong(_ clips: [BenchClip], on engine: TranscriptionEngine,
                         peak: PeakSampler) async throws -> BenchResults.Long {
        var results: [BenchResults.LongClip] = []
        for clip in clips {
            let job = try await timedTranscribe(clip, on: engine, peak: peak)
            results.append(.init(id: clip.id, audioSeconds: clip.audioSeconds, processingSeconds: job.seconds,
                                 realTimeFactor: BenchStats.realTimeFactor(processingSeconds: job.seconds,
                                                                           audioSeconds: clip.audioSeconds),
                                 transcript: .init(reference: clip.reference, hypothesis: job.text)))
        }
        let audio = results.map(\.audioSeconds).reduce(0, +)
        let processing = results.map(\.processingSeconds).reduce(0, +)
        return BenchResults.Long(
            clips: results,
            realTimeFactor: results.isEmpty ? nil
                : BenchStats.realTimeFactor(processingSeconds: processing, audioSeconds: audio),
            wer: WordErrorRate.total(results.map(\.transcript.wer)))
    }
}

/// What one bench run measured. Encoded into `BenchReport`.
struct BenchResults: Codable, Equatable {
    struct Load: Codable, Equatable {
        /// The adapter's own load (e.g. reading weights, building the GPU context).
        let adapterSeconds: Double
        /// The engine's 1 s silent warm-up job, which it runs before reporting ready.
        let warmUpSeconds: Double
        /// `load()` to ready: what the user waits for at launch.
        let totalSeconds: Double
    }

    /// The bench process's physical footprint (`phys_footprint`, what Activity
    /// Monitor calls Memory; on Apple Silicon it includes Metal buffers), in
    /// bytes. An engine that runs in another process (an OS speech service)
    /// isn't counted.
    struct Memory: Codable, Equatable {
        /// Before the model loads (fixtures are already decoded).
        let baselineBytes: UInt64
        /// After load and warm-up: the resident model.
        let loadedBytes: UInt64
        /// Highest footprint sampled (on a timer and between jobs) from the
        /// start of the load to the end of the run: the engine's peak.
        let peakBytes: UInt64
        /// The kernel's `ri_lifetime_max_phys_footprint` at the end: an upper
        /// bound that also counts fixture decoding before the load.
        let lifetimePeakBytes: UInt64
    }

    /// A clip's reference, what the engine heard, and the WER between them.
    struct ScoredTranscript: Codable, Equatable {
        let reference: String
        /// Trimmed; for short clips, from the first run.
        let hypothesis: String
        let wer: WordErrorRate

        init(reference: String, hypothesis: String) {
            self.reference = reference
            self.hypothesis = hypothesis
            wer = WordErrorRate.score(reference: reference, hypothesis: hypothesis)
        }
    }

    struct ShortClip: Codable, Equatable {
        let id: String
        let audioSeconds: Double
        /// `transcribe` wall time for each run, in run order.
        let latenciesSeconds: [Double]
        let medianLatencySeconds: Double
        let transcript: ScoredTranscript
    }

    struct Short: Codable, Equatable {
        let clips: [ShortClip]
        /// Over every run of every clip; null if there were no short clips.
        @NullWhenAbsent var latency: BenchStats.LatencySummary?
        /// Pooled over the clips.
        let wer: WordErrorRate
    }

    struct LongClip: Codable, Equatable {
        let id: String
        let audioSeconds: Double
        let processingSeconds: Double
        let realTimeFactor: Double
        let transcript: ScoredTranscript
    }

    struct Long: Codable, Equatable {
        let clips: [LongClip]
        /// Total processing over total audio; null if there were no long clips.
        @NullWhenAbsent var realTimeFactor: Double?
        let wer: WordErrorRate
    }

    let load: Load
    /// Null if the footprint couldn't be read.
    @NullWhenAbsent var memory: Memory?
    let short: Short
    let long: Long
}

/// A reading of the process's physical memory footprint.
struct MemorySnapshot: Equatable {
    let footprintBytes: UInt64
    let lifetimePeakBytes: UInt64

    /// This process, via `proc_pid_rusage(RUSAGE_INFO_V4)`.
    static func current() -> MemorySnapshot? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }
        return MemorySnapshot(footprintBytes: info.ri_phys_footprint,
                              lifetimePeakBytes: info.ri_lifetime_max_phys_footprint)
    }
}

/// The highest footprint seen, sampled on a timer and on demand.
private final class PeakSampler: @unchecked Sendable {
    private let memory: () -> MemorySnapshot?
    private let lock = NSLock()
    private var _max: UInt64?
    private var timer: DispatchSourceTimer?

    init(memory: @escaping () -> MemorySnapshot?) { self.memory = memory }

    var max: UInt64? { lock.withLock { _max } }

    func sample() {
        guard let now = memory()?.footprintBytes else { return }
        lock.withLock { _max = Swift.max(_max ?? 0, now) }
    }

    /// The timer runs at the engine queue's QoS, so a busy engine can't starve it.
    func start(every interval: TimeInterval) {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// A span on the bench clock.
private struct Interval {
    let start: TimeInterval
    let end: TimeInterval
    var seconds: TimeInterval { end - start }
}

/// Load timings, written on the engine's queue and read by the runner.
private final class LoadTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var adapterSeconds: TimeInterval = 0
    private var adapter: TimedAdapter?

    func set(adapterSeconds: TimeInterval, adapter: TimedAdapter) {
        lock.withLock {
            self.adapterSeconds = adapterSeconds
            self.adapter = adapter
        }
    }

    /// The factory's time, and the adapter's first call (the engine's warm-up).
    func get() -> (adapterSeconds: TimeInterval, warmUp: Interval?) {
        lock.withLock { (adapterSeconds, adapter?.firstCall) }
    }
}

/// Forwards to the real adapter, recording when its first call ran.
private final class TimedAdapter: TranscriptionAdapter {
    private let inner: TranscriptionAdapter
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var _firstCall: Interval?

    init(_ inner: TranscriptionAdapter, clock: @escaping () -> TimeInterval) {
        self.inner = inner
        self.clock = clock
    }

    var firstCall: Interval? { lock.withLock { _firstCall } }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        let start = clock()
        defer {
            let end = clock()
            lock.withLock { if _firstCall == nil { _firstCall = Interval(start: start, end: end) } }
        }
        return try inner.transcribe(samples: samples)
    }
}
