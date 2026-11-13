import XCTest
@testable import VoiceType

/// Tests for the bench harness: stats, manifest parsing, the run loop through
/// `TranscriptionEngine` (driven by a fake adapter on a fake clock, so timings
/// are exact), and the JSON/table output.
final class BenchTests: XCTestCase {

    // MARK: - Percentiles

    func testPercentileInterpolatesBetweenRanks() {
        let values: [Double] = [10, 1, 9, 2, 8, 3, 7, 4, 6, 5]   // unsorted on purpose
        XCTAssertEqual(BenchStats.percentile(values, 50)!, 5.5, accuracy: 1e-9)
        XCTAssertEqual(BenchStats.percentile(values, 90)!, 9.1, accuracy: 1e-9)
        XCTAssertEqual(BenchStats.percentile(values, 0)!, 1)
        XCTAssertEqual(BenchStats.percentile(values, 100)!, 10)
    }

    func testPercentileOfOneValueIsThatValueAndOfNoneIsNil() {
        XCTAssertEqual(BenchStats.percentile([0.42], 90), 0.42)
        XCTAssertNil(BenchStats.percentile([], 50))
    }

    func testLatencySummary() {
        let summary = BenchStats.LatencySummary([0.2, 0.4, 0.3])!
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.p50Seconds, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.meanSeconds, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.maxSeconds, 0.4)
        XCTAssertNil(BenchStats.LatencySummary([]))
    }

    func testRealTimeFactorIsProcessingOverAudio() {
        XCTAssertEqual(BenchStats.realTimeFactor(processingSeconds: 30, audioSeconds: 600), 0.05, accuracy: 1e-12)
        XCTAssertEqual(BenchStats.realTimeFactor(processingSeconds: 1, audioSeconds: 0), 0)
    }

    // MARK: - Manifest

    func testManifestParsesKindPathAndReferenceRelativeToItsDirectory() throws {
        let dir = URL(fileURLWithPath: "/tmp/fixtures")
        let text = """
        # kind<TAB>path<TAB>reference
        short\tclips/jfk.wav\tAnd so, my fellow Americans.

        long\tlong/1089-134686.wav\tHE HOPED THERE WOULD BE STEW
        short\t/abs/other.flac\tHELLO
        """
        let entries = try BenchManifest.parse(text, relativeTo: dir)
        XCTAssertEqual(entries, [
            .init(id: "jfk", kind: .short, file: URL(fileURLWithPath: "/tmp/fixtures/clips/jfk.wav"),
                  reference: "And so, my fellow Americans."),
            .init(id: "1089-134686", kind: .long, file: URL(fileURLWithPath: "/tmp/fixtures/long/1089-134686.wav"),
                  reference: "HE HOPED THERE WOULD BE STEW"),
            .init(id: "other", kind: .short, file: URL(fileURLWithPath: "/abs/other.flac"), reference: "HELLO"),
        ])
    }

    func testManifestRejectsUnknownKindAndMissingColumnsWithTheLineNumber() {
        let dir = URL(fileURLWithPath: "/tmp")
        XCTAssertThrowsError(try BenchManifest.parse("short\ta.wav\tok\nmedium\tb.wav\tx", relativeTo: dir)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("line 2"), "\($0.localizedDescription)")
        }
        XCTAssertThrowsError(try BenchManifest.parse("long\tonly-a-path.wav", relativeTo: dir)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("line 1"), "\($0.localizedDescription)")
        }
    }

    // MARK: - Runner

    /// A clock tests advance by hand; the fake adapter advances it to simulate
    /// work, so every measured duration is exact.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 1_000
        func now() -> TimeInterval { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    /// Works at a fixed 0.1× real time and answers each clip (keyed by its
    /// sample count) with a canned transcript.
    private final class FakeAdapter: TranscriptionAdapter {
        let clock: FakeClock
        let answers: [Int: String]
        let onTranscribe: (Int) -> Void
        private let lock = NSLock()
        private var _jobs: [Int] = []
        var jobs: [Int] { lock.withLock { _jobs } }

        init(clock: FakeClock, answers: [Int: String], onTranscribe: @escaping (Int) -> Void = { _ in }) {
            self.clock = clock
            self.answers = answers
            self.onTranscribe = onTranscribe
        }

        func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
            lock.withLock { _jobs.append(samples.count) }
            onTranscribe(samples.count)
            clock.advance(Double(samples.count) / 16_000 * 0.1)
            return [Transcript.Segment(text: answers[samples.count] ?? "", start: 0, end: 1)]
        }
    }

    private var modelURL: URL!

    override func setUp() {
        super.setUp()
        modelURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bench-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data(count: 1234))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelURL)
        super.tearDown()
    }

    private func clip(_ id: String, _ kind: BenchClip.Kind, seconds: Double, reference: String) -> BenchClip {
        BenchClip(id: id, kind: kind, reference: reference,
                  samples: [Float](repeating: 0.1, count: Int(seconds * 16_000)))
    }

    private struct Fixture {
        let adapter: FakeAdapter
        let runner: BenchRunner
        let clips: [BenchClip]
    }

    private func fixture(shortRuns: Int = 2, memory: @escaping () -> MemorySnapshot? = { nil }) -> Fixture {
        let clock = FakeClock()
        let clips = [
            clip("a", .short, seconds: 2, reference: "the cat sat"),
            clip("b", .short, seconds: 4, reference: "on the mat"),
            clip("book", .long, seconds: 600, reference: "one two three four"),
        ]
        let adapter = FakeAdapter(clock: clock, answers: [
            32_000: " The cat sat.",
            64_000: " on a mat",
            9_600_000: " one two three",
        ])
        let engine = BenchEngine(id: "fake") { [adapter] _ in
            clock.advance(2)      // model load
            return adapter
        }
        var runner = BenchRunner(engine: engine, model: ModelSpec(path: modelURL.path, sha256: nil, language: "en"), shortRuns: shortRuns)
        runner.clock = clock.now
        runner.memory = memory
        return Fixture(adapter: adapter, runner: runner, clips: clips)
    }

    func testLoadTimeSplitsAdapterLoadFromWarmUp() async throws {
        let f = fixture()
        let results = try await f.runner.run(f.clips)
        XCTAssertEqual(results.load.adapterSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(results.load.warmUpSeconds, 0.1, accuracy: 1e-9, "1 s of silence at 0.1× real time")
        XCTAssertEqual(results.load.totalSeconds, 2.1, accuracy: 1e-9)
    }

    func testShortClipsRunRepeatedlyThroughTheEngineAfterTheWarmUp() async throws {
        let f = fixture(shortRuns: 3)
        let results = try await f.runner.run(f.clips)

        XCTAssertEqual(f.adapter.jobs, [16_000] + Array(repeating: [32_000, 64_000], count: 3).flatMap { $0 } + [9_600_000],
                       "Warm-up first, short clips round-robin per run, then the long clip once")
        XCTAssertEqual(results.short.clips.map(\.id), ["a", "b"])
        XCTAssertEqual(results.short.clips[0].latenciesSeconds.count, 3)
        for latency in results.short.clips[0].latenciesSeconds { XCTAssertEqual(latency, 0.2, accuracy: 1e-9) }
        XCTAssertEqual(results.short.clips[1].medianLatencySeconds, 0.4, accuracy: 1e-9)

        let latency = try XCTUnwrap(results.short.latency)
        XCTAssertEqual(latency.count, 6, "Percentiles cover every run of every clip")
        XCTAssertEqual(latency.p50Seconds, 0.3, accuracy: 1e-9)
        XCTAssertEqual(latency.maxSeconds, 0.4, accuracy: 1e-9)
    }

    func testWERIsScoredPerClipAndPooledForShortDictation() async throws {
        let f = fixture()
        let results = try await f.runner.run(f.clips)

        XCTAssertEqual(results.short.clips[0].transcript.hypothesis, "The cat sat.", "Hypothesis is trimmed")
        XCTAssertEqual(results.short.clips[0].transcript.wer.errors, 0)
        XCTAssertEqual(results.short.clips[1].transcript.wer, WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 3))
        XCTAssertEqual(results.short.wer, WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 6))
        XCTAssertEqual(results.long.clips[0].transcript.wer.deletions, 1)
    }

    func testLongClipReportsRealTimeFactor() async throws {
        let f = fixture()
        let results = try await f.runner.run(f.clips)

        let book = try XCTUnwrap(results.long.clips.first)
        XCTAssertEqual(book.id, "book")
        XCTAssertEqual(book.audioSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(book.processingSeconds, 60, accuracy: 1e-9)
        XCTAssertEqual(book.realTimeFactor, 0.1, accuracy: 1e-9)
        XCTAssertEqual(results.long.realTimeFactor ?? -1, 0.1, accuracy: 1e-9)
    }

    /// A footprint the fake engine moves: up when the model loads, up again
    /// while the long clip runs (and, like whisper's buffers, it stays up).
    private final class FakeMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var footprint: UInt64 = 100
        func set(_ bytes: UInt64) { lock.withLock { footprint = bytes } }
        func snapshot() -> MemorySnapshot? {
            lock.withLock { MemorySnapshot(footprintBytes: footprint, lifetimePeakBytes: 5_000) }
        }
    }

    func testMemoryReportsBaselineLoadedAndPeakFootprints() async throws {
        let memory = FakeMemory()
        let clock = FakeClock()
        let long = clip("book", .long, seconds: 60, reference: "x")
        let engine = BenchEngine(id: "fake") { [long] _ in
            memory.set(400)
            return FakeAdapter(clock: clock, answers: [:], onTranscribe: { count in
                if count == long.samples.count { memory.set(900) }
            })
        }
        var runner = BenchRunner(engine: engine, model: ModelSpec(path: modelURL.path, sha256: nil, language: "en"), shortRuns: 1)
        runner.clock = clock.now
        runner.memory = memory.snapshot

        let results = try await runner.run([clip("a", .short, seconds: 1.5, reference: "x"), long])

        XCTAssertEqual(results.memory, BenchResults.Memory(baselineBytes: 100, loadedBytes: 400,
                                                           peakBytes: 900, lifetimePeakBytes: 5_000))
    }

    func testMissingModelFailsBeforeAnyJob() async {
        let engine = BenchEngine(id: "fake") { _ in XCTFail("must not load"); throw TranscriptionError.inferenceFailed }
        let runner = BenchRunner(engine: engine, model: ModelSpec(path: "/nonexistent/model.bin", sha256: nil, language: "en"), shortRuns: 1)
        do {
            _ = try await runner.run([])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("/nonexistent/model.bin"), error.localizedDescription)
        }
    }

    func testMemorySamplingStaysOutsideTheTimedWindow() async throws {
        // Every memory read costs a fake second; latencies must not see any.
        let clock = FakeClock()
        let adapter = FakeAdapter(clock: clock, answers: [:])
        var runner = BenchRunner(engine: BenchEngine(id: "fake") { _ in adapter }, model: ModelSpec(path: modelURL.path, sha256: nil, language: "en"), shortRuns: 2)
        runner.clock = clock.now
        runner.memorySampleInterval = 3600     // timer off: only the deterministic samples
        runner.memory = {
            clock.advance(1)
            return MemorySnapshot(footprintBytes: 1, lifetimePeakBytes: 1)
        }

        let results = try await runner.run([clip("a", .short, seconds: 2, reference: "x"),
                                            clip("book", .long, seconds: 60, reference: "x")])

        XCTAssertEqual(results.short.clips[0].latenciesSeconds.count, 2)
        for latency in results.short.clips[0].latenciesSeconds { XCTAssertEqual(latency, 0.2, accuracy: 1e-9) }
        XCTAssertEqual(results.long.clips[0].processingSeconds, 6, accuracy: 1e-9)
        XCTAssertEqual(results.load.totalSeconds, 0.1, accuracy: 1e-9)
    }

    func testEveryRegisteredEngineHasAUniqueID() {
        let ids = BenchEngine.all(.init(language: "en", threads: 0)).map(\.id)
        XCTAssertTrue(ids.contains("whisper"))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTheBenchRunsEveryEngineThisMacCanFromTheRegistry() throws {
        let engines = EngineRegistry([WhisperEngine(), FakeEngine(kind: .appleSpeech, minimumMacOS: 26)])
        let options = BenchEngine.Options(language: "en", threads: 0)
        XCTAssertEqual(BenchEngine.all(options, engines: engines, environment: .mac(26)).map(\.id),
                       ["whisper", "apple-speech"])
        XCTAssertEqual(BenchEngine.all(options, engines: engines, environment: .mac(15)).map(\.id), ["whisper"])

        let apple = try BenchEngine.resolve("apple-speech", options, engines: engines, environment: .mac(26))
        let spec = apple.modelSpec("/m/thing", "en")
        XCTAssertEqual(spec.engine, .appleSpeech, "The --model argument becomes that engine's spec")
        XCTAssertEqual(try apple.makeAdapter(spec).transcribe(samples: []).first?.text, "apple-speech:thing")
    }

    func testAnEngineTheBenchCantRunIsAClearError() {
        let engines = EngineRegistry([WhisperEngine(), FakeEngine(kind: .appleSpeech, minimumMacOS: 26)])
        let options = BenchEngine.Options(language: "en", threads: 0)
        for (id, message) in [("apple-speech", "can't bench apple-speech: Apple Speech needs macOS 26"),
                              ("parakeet", "can't bench parakeet: Turbo (English/EU) isn't in this build"),
                              ("nope", "can't bench nope: \"nope\" isn't a known engine "
                                       + "(engines: whisper, whisperkit, parakeet, apple-speech)")] {
            XCTAssertThrowsError(try BenchEngine.resolve(id, options, engines: engines, environment: .mac(15))) {
                XCTAssertEqual($0.localizedDescription, message)
            }
        }
    }

    func testAWhisperModelArgumentIsVerifiedByTheCatalog() throws {
        let whisper = try BenchEngine.resolve("whisper", .init(language: "en", threads: 0))
        XCTAssertEqual(whisper.modelSpec("/m/ggml-tiny.en.bin", "en"), .file("/m/ggml-tiny.en.bin"))
        XCTAssertNotNil(whisper.modelSpec("/m/ggml-tiny.en.bin", "en").sha256)
    }

    // MARK: - Tuning flags

    private func tuning(_ args: [String], exists: Bool = true) throws -> WhisperTuning {
        try BenchCommand.tuning(from: ["VoiceType", "--bench", "--model", "m.bin"] + args, fileExists: { _ in exists })
    }

    func testNoTuningFlagsMeansTheAppDefaults() throws {
        XCTAssertEqual(try tuning([]), .default)
    }

    func testEveryTuningFlagParses() throws {
        let t = try tuning(["--suppress-nst", "on", "--audio-ctx", "clip", "--temp-fallback", "off",
                            "--vad", "/m/ggml-silero-v6.2.0.bin"])
        XCTAssertTrue(t.suppressNonSpeech)
        XCTAssertEqual(t.audioContext, .sizedToClip)
        XCTAssertFalse(t.temperatureFallback)
        XCTAssertEqual(t.vad, .silero(modelPath: "/m/ggml-silero-v6.2.0.bin"))

        let back = try tuning(["--suppress-nst", "off", "--audio-ctx", "off", "--temp-fallback", "on", "--vad", "off"])
        XCTAssertEqual(back, .default)
    }

    func testBadTuningValuesAreRejectedNamingTheFlag() {
        for (args, flag) in [(["--audio-ctx", "sized"], "--audio-ctx"), (["--temp-fallback", "yes"], "--temp-fallback"),
                             (["--suppress-nst", "1"], "--suppress-nst")] {
            XCTAssertThrowsError(try tuning(args)) {
                XCTAssertTrue($0.localizedDescription.contains(flag), $0.localizedDescription)
            }
        }
        XCTAssertThrowsError(try tuning(["--vad", "/nope/ggml-silero.bin"], exists: false)) {
            XCTAssertTrue($0.localizedDescription.contains("/nope/ggml-silero.bin"), $0.localizedDescription)
        }
    }

    func testEnginesGetTheTuning() {
        var options = BenchEngine.Options(language: "en", threads: 0)
        XCTAssertEqual(options.whisper, .default)
        options.whisper.audioContext = .sizedToClip
        XCTAssertNotNil(BenchEngine.named("whisper", options))
    }

    // MARK: - Model size

    func testModelSizeIsAFilesSizeOrADirectorysTotalOrNil() throws {
        XCTAssertEqual(BenchCommand.diskSize(of: modelURL), 1234)
        XCTAssertNil(BenchCommand.diskSize(of: URL(fileURLWithPath: "/nonexistent/model.bin")))

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-\(UUID().uuidString).mlmodelc")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("weights"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model.mil").path, contents: Data(count: 100))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("weights/weight.bin").path, contents: Data(count: 900))
        XCTAssertEqual(BenchCommand.diskSize(of: dir), 1000)
    }

    // MARK: - Output

    private let sampleTuning: WhisperTuning = {
        var t = WhisperTuning.default
        t.suppressNonSpeech = true
        t.audioContext = .sizedToClip
        t.temperatureFallback = false
        return t
    }()

    private func sampleReport(memory: MemorySnapshot? = MemorySnapshot(footprintBytes: 50_000_000,
                                                                       lifetimePeakBytes: 300_000_000),
                              gitSHA: String? = "abc1234", modelBytes: UInt64? = 1234,
                              cores: Int? = 8) async throws -> BenchReport {
        let f = fixture(memory: { memory })
        let results = try await f.runner.run(f.clips)
        return BenchReport(
            createdAt: "2026-11-04T12:00:00Z",
            machine: .init(chip: "Apple M2 Pro", model: "Mac14,10", memoryBytes: 32 << 30,
                           performanceCores: cores, efficiencyCores: cores.map { $0 / 2 },
                           osVersion: "15.1 (24B83)", thermalStateAtStart: "nominal", thermalStateAtEnd: "fair"),
            engine: .init(id: "fake", modelFile: "ggml-tiny.en.bin", modelBytes: modelBytes),
            build: .init(configuration: "release", gitSHA: gitSHA),
            settings: .init(shortRuns: 2, language: "en", threads: 0, whisper: sampleTuning),
            results: results)
    }

    func testAbsentValuesAreExplicitNullsSoTheKeySetNeverVaries() async throws {
        let full = try await sampleReport()
        let sparse = try await sampleReport(memory: nil, gitSHA: nil, modelBytes: nil, cores: nil)

        func keyPaths(_ data: Data) throws -> Set<String> {
            func walk(_ value: Any, _ path: String) -> [String] {
                guard let object = value as? [String: Any] else { return [path] }
                return object.flatMap { walk($1, path + "." + $0) }
            }
            return Set(walk(try JSONSerialization.jsonObject(with: data), ""))
        }
        let fullKeys = try keyPaths(full.jsonData())
        let sparseKeys = try keyPaths(sparse.jsonData())
        for path in [".results.memory", ".build.gitSHA", ".engine.modelBytes", ".machine.performanceCores"] {
            XCTAssertTrue(sparseKeys.contains(path), "\(path) must be present as null")
        }
        XCTAssertTrue(fullKeys.isSuperset(of: sparseKeys.subtracting([".results.memory"])))
        XCTAssertEqual(try JSONDecoder().decode(BenchReport.self, from: sparse.jsonData()), sparse, "Nulls round-trip")

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: sparse.jsonData()) as? [String: Any])
        XCTAssertTrue((object["build"] as? [String: Any])?["gitSHA"] is NSNull)
    }

    func testJSONHasAStableVersionedSchema() async throws {
        let report = try await sampleReport()
        let data = try report.jsonData()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "createdAt", "machine", "engine", "build", "settings", "results"])
        let settings = try XCTUnwrap(object["settings"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), ["shortRuns", "language", "threads", "whisper"])
        let whisper = try XCTUnwrap(settings["whisper"] as? [String: Any])
        XCTAssertEqual(Set(whisper.keys), ["suppressNonSpeech", "audioContext", "temperatureFallback", "vad"])
        XCTAssertEqual(whisper["audioContext"] as? String, "clip")
        XCTAssertEqual(whisper["temperatureFallback"] as? Bool, false)
        let results = try XCTUnwrap(object["results"] as? [String: Any])
        XCTAssertEqual(Set(results.keys), ["load", "memory", "short", "long"])

        XCTAssertEqual(try JSONDecoder().decode(BenchReport.self, from: data), report, "JSON round-trips")
        XCTAssertEqual(try report.jsonData(), data, "Encoding is deterministic (sorted keys)")
    }

    func testTableShowsEveryClipAndTheHeadlineNumbers() async throws {
        let table = try await sampleReport().table()
        for needle in ["fake", "ggml-tiny.en.bin", "Apple M2 Pro", "nominal → fair", "a", "b", "book",
                       "p50", "p90", "RTF", "WER", "16.7%", "0.100", "2.00s", "0.10s", "200 ms", "286 MiB",
                       "language en · threads auto · suppress-nst on · audio-ctx clip · temp-fallback off · vad off"] {
            XCTAssertTrue(table.contains(needle), "table is missing \(needle):\n\(table)")
        }
    }
}
