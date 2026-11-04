import Foundation

/// A speech engine the bench can run: an id for the report and the same
/// model-path → adapter factory `TranscriptionEngine` takes.
struct BenchEngine {
    let id: String
    let makeAdapter: (String) throws -> TranscriptionAdapter

    /// Every engine `--bench --engine <id>` accepts. To bench a new adapter,
    /// add one line here.
    static let all: [BenchEngine] = [
        BenchEngine(id: "whisper") { try WhisperAdapter(modelPath: $0, language: "en", threads: 0) },
    ]

    static func named(_ id: String) -> BenchEngine? { all.first { $0.id == id } }
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

enum BenchError: LocalizedError {
    case modelMissing(path: String)
    case loadFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "model file not found at \(path)"
        case .loadFailed(let reason): return "model failed to load: \(reason)"
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
    let modelPath: String
    /// Passes over the short clips; more runs steady the percentiles.
    var shortRuns: Int

    /// Monotonic seconds; injectable so tests can fake the passage of time.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The process's memory now; nil if it can't be read.
    var memory: () -> MemorySnapshot? = MemorySnapshot.current
    /// How often memory is sampled between jobs (it's also sampled after each).
    var memorySampleInterval: TimeInterval = 0.005

    init(engine: BenchEngine, modelPath: String, shortRuns: Int) {
        self.engine = engine
        self.modelPath = modelPath
        self.shortRuns = shortRuns
    }

    func run(_ clips: [BenchClip]) async throws -> BenchResults {
        let baseline = memory()
        let peak = PeakSampler(memory: memory)
        peak.start(every: memorySampleInterval)
        defer { peak.stop() }

        // Wrap the adapter so the bench sees exactly what the engine does: how
        // long the factory took, and when the engine's warm-up job finished.
        let timing = LoadTiming()
        let engineID = engine.id
        let transcriptionEngine = TranscriptionEngine(modelPath: modelPath) { [clock, make = engine.makeAdapter] path in
            let start = clock()
            let inner = try make(path)
            let adapter = TimedAdapter(inner, clock: clock, afterEachCall: peak.sample)
            timing.set(adapterSeconds: clock() - start, adapter: adapter)
            return adapter
        }

        let loadStart = clock()
        transcriptionEngine.load()
        while transcriptionEngine.status == .loading { try await Task.sleep(nanoseconds: 1_000_000) }
        switch transcriptionEngine.status {
        case .ready: break
        case .missing: throw BenchError.modelMissing(path: modelPath)
        case .failed(let reason): throw BenchError.loadFailed(reason: reason)
        case .notLoaded, .loading: throw BenchError.loadFailed(reason: "\(engineID) never finished loading")
        }
        // The warm-up is the adapter's first call; the engine reports ready
        // right after it, so the load ends when it does (not when we polled).
        let (adapterSeconds, warmUp) = timing.get()
        let loadEnd = warmUp?.end ?? clock()
        let load = BenchResults.Load(adapterSeconds: adapterSeconds,
                                     warmUpSeconds: warmUp.map { $0.end - $0.start } ?? 0,
                                     totalSeconds: loadEnd - loadStart)
        let loaded = memory()

        let short = try await runShort(clips.filter { $0.kind == .short }, on: transcriptionEngine)
        let long = try await runLong(clips.filter { $0.kind == .long }, on: transcriptionEngine)

        peak.sample()
        let end = memory()
        var memoryResult: BenchResults.Memory?
        if let baseline, let loaded, let end, let peakBytes = peak.max {
            memoryResult = .init(baselineBytes: baseline.footprintBytes, loadedBytes: loaded.footprintBytes,
                                 peakBytes: peakBytes, lifetimePeakBytes: end.lifetimePeakBytes)
        }
        return BenchResults(load: load, memory: memoryResult, short: short, long: long)
    }

    private func runShort(_ clips: [BenchClip], on engine: TranscriptionEngine) async throws -> BenchResults.Short {
        var latencies = [[Double]](repeating: [], count: clips.count)
        var hypotheses = [String](repeating: "", count: clips.count)
        // Round-robin, so slow drift (thermals, background load) spreads over
        // every clip instead of landing on one.
        for run in 0..<max(shortRuns, 1) {
            for (i, clip) in clips.enumerated() {
                let start = clock()
                let text = try await engine.transcribe(clip.samples).text
                latencies[i].append(clock() - start)
                if run == 0 { hypotheses[i] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        let results = clips.enumerated().map { i, clip in
            BenchResults.ShortClip(id: clip.id, audioSeconds: clip.audioSeconds,
                                   latenciesSeconds: latencies[i],
                                   medianLatencySeconds: BenchStats.percentile(latencies[i], 50) ?? 0,
                                   reference: clip.reference, hypothesis: hypotheses[i],
                                   wer: WordErrorRate.score(reference: clip.reference, hypothesis: hypotheses[i]))
        }
        return BenchResults.Short(clips: results, latency: BenchStats.LatencySummary(latencies.flatMap { $0 }),
                                  wer: WordErrorRate.total(results.map(\.wer)))
    }

    private func runLong(_ clips: [BenchClip], on engine: TranscriptionEngine) async throws -> BenchResults.Long {
        var results: [BenchResults.LongClip] = []
        for clip in clips {
            let start = clock()
            let text = try await engine.transcribe(clip.samples).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = clock() - start
            results.append(.init(id: clip.id, audioSeconds: clip.audioSeconds, processingSeconds: seconds,
                                 realTimeFactor: BenchStats.realTimeFactor(processingSeconds: seconds,
                                                                           audioSeconds: clip.audioSeconds),
                                 reference: clip.reference, hypothesis: text,
                                 wer: WordErrorRate.score(reference: clip.reference, hypothesis: text)))
        }
        let audio = results.map(\.audioSeconds).reduce(0, +)
        let processing = results.map(\.processingSeconds).reduce(0, +)
        return BenchResults.Long(
            clips: results,
            realTimeFactor: results.isEmpty ? nil
                : BenchStats.realTimeFactor(processingSeconds: processing, audioSeconds: audio),
            wer: WordErrorRate.total(results.map(\.wer)))
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

    /// Process physical footprint (`phys_footprint`, what Activity Monitor
    /// calls Memory; on Apple Silicon it includes Metal buffers), in bytes.
    struct Memory: Codable, Equatable {
        /// Before the model loads (fixtures are already decoded).
        let baselineBytes: UInt64
        /// After load and warm-up: the resident model.
        let loadedBytes: UInt64
        /// Highest footprint sampled (every 5 ms and after each job) from the
        /// start of the load to the end of the run: the engine's peak.
        let peakBytes: UInt64
        /// The kernel's `ri_lifetime_max_phys_footprint` at the end: an upper
        /// bound that also counts fixture decoding before the load.
        let lifetimePeakBytes: UInt64
    }

    struct ShortClip: Codable, Equatable {
        let id: String
        let audioSeconds: Double
        /// `transcribe` wall time for each run, in run order.
        let latenciesSeconds: [Double]
        let medianLatencySeconds: Double
        let reference: String
        /// From the first run.
        let hypothesis: String
        let wer: WordErrorRate
    }

    struct Short: Codable, Equatable {
        let clips: [ShortClip]
        /// Over every run of every clip; nil if there were no short clips.
        let latency: BenchStats.LatencySummary?
        /// Pooled over the clips.
        let wer: WordErrorRate
    }

    struct LongClip: Codable, Equatable {
        let id: String
        let audioSeconds: Double
        let processingSeconds: Double
        let realTimeFactor: Double
        let reference: String
        let hypothesis: String
        let wer: WordErrorRate
    }

    struct Long: Codable, Equatable {
        let clips: [LongClip]
        /// Total processing over total audio; nil if there were no long clips.
        let realTimeFactor: Double?
        let wer: WordErrorRate
    }

    let load: Load
    /// nil if the footprint couldn't be read.
    let memory: Memory?
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

    func start(every interval: TimeInterval) {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
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

    /// The adapter load time and the first call (the engine's warm-up).
    func get() -> (TimeInterval, (start: TimeInterval, end: TimeInterval)?) {
        lock.withLock { (adapterSeconds, adapter?.firstCall) }
    }
}

/// Forwards to the real adapter, recording when its first call ran and
/// sampling memory after every call.
private final class TimedAdapter: TranscriptionAdapter {
    private let inner: TranscriptionAdapter
    private let clock: () -> TimeInterval
    private let afterEachCall: () -> Void
    private let lock = NSLock()
    private var _firstCall: (start: TimeInterval, end: TimeInterval)?

    init(_ inner: TranscriptionAdapter, clock: @escaping () -> TimeInterval, afterEachCall: @escaping () -> Void) {
        self.inner = inner
        self.clock = clock
        self.afterEachCall = afterEachCall
    }

    var firstCall: (start: TimeInterval, end: TimeInterval)? { lock.withLock { _firstCall } }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        let start = clock()
        defer {
            let end = clock()
            lock.withLock { if _firstCall == nil { _firstCall = (start, end) } }
            afterEachCall()
        }
        return try inner.transcribe(samples: samples)
    }
}
