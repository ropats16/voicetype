import XCTest
@testable import VoiceType

/// The engine's model lifecycle through its interface: checksum verification,
/// hot-swapping models under in-flight jobs, and idle unload. Fake adapters
/// stand in for whisper.cpp — no model, no Metal.
@MainActor
final class EngineModelLifecycleTests: XCTestCase {

    // MARK: - Fakes

    /// Builds one fake adapter per load, named after the model file, and logs
    /// adapters made, freed, and the real (non-warm-up) jobs they start.
    private final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var _made: [String] = []
        private var _freed: [String] = []
        private var _started: [String] = []
        /// Real jobs on the named model wait on its gate.
        var gates: [String: DispatchSemaphore] = [:]

        var made: [String] { lock.withLock { _made } }
        var freed: [String] { lock.withLock { _freed } }
        var started: [String] { lock.withLock { _started } }

        func make(_ spec: ModelSpec) -> TranscriptionAdapter {
            let name = URL(fileURLWithPath: spec.path).deletingPathExtension().lastPathComponent
            lock.withLock { _made.append(name) }
            return FakeAdapter(name: name, gate: gates[name], factory: self)
        }

        fileprivate func log(started name: String) { lock.withLock { _started.append(name) } }
        fileprivate func log(freed name: String) { lock.withLock { _freed.append(name) } }
    }

    private final class FakeAdapter: TranscriptionAdapter {
        let name: String
        let gate: DispatchSemaphore?
        weak var factory: Factory?

        init(name: String, gate: DispatchSemaphore?, factory: Factory) {
            self.name = name
            self.gate = gate
            self.factory = factory
        }

        deinit { factory?.log(freed: name) }

        func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
            // The warm-up is silence; only real jobs are logged and gated.
            if samples.contains(where: { $0 != 0 }) {
                factory?.log(started: name)
                gate?.wait()
            }
            return [Transcript.Segment(text: "\(name):\(samples.count)", start: 0, end: 1)]
        }
    }

    // MARK: - State

    private var dir: URL!
    private var factory: Factory!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        factory = Factory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A model file holding `contents`, and a spec for it.
    private func modelFile(_ name: String, contents: String = "weights", sha256: String? = nil) -> ModelSpec {
        let url = dir.appendingPathComponent("\(name).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return ModelSpec(path: url.path, sha256: sha256, language: "en")
    }

    private func makeEngine(_ spec: ModelSpec, idleUnloadAfter: TimeInterval? = nil) -> TranscriptionEngine {
        TranscriptionEngine(model: spec, idleUnloadAfter: idleUnloadAfter,
                            verifier: ModelVerifier(cacheURL: nil),
                            makeAdapter: { [factory] in factory!.make($0) })
    }

    /// Every status the engine reports (on main) from now on.
    private final class StatusLog { var seen: [TranscriptionStatus] = [] }

    private func record(_ engine: TranscriptionEngine) -> StatusLog {
        let log = StatusLog()
        engine.onStatusChange = { log.seen.append($0) }
        return log
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func sha256(_ s: String) -> String {
        SHA256Hex.of(Data(s.utf8))
    }

    // MARK: - Checksum

    func testChecksumMismatchFailsWithoutUsingTheFile() async {
        let spec = modelFile("ggml-bad", contents: "truncated", sha256: sha256("the real weights"))
        let engine = makeEngine(spec)
        let log = record(engine)

        engine.load()
        await waitUntil("settled") { log.seen.last.map { $0 != .loading } ?? false }

        guard case .failed(let reason) = engine.status else { return XCTFail("expected failed, got \(engine.status)") }
        XCTAssertTrue(reason.contains("ggml-bad.bin") && reason.contains("checksum"), reason)
        XCTAssertEqual(factory.made, [], "A file failing its checksum is never handed to the engine")
        do {
            _ = try await engine.transcribe([0.1])
            XCTFail("expected modelNotLoaded")
        } catch TranscriptionError.modelNotLoaded {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMatchingChecksumLoads() async throws {
        let engine = makeEngine(modelFile("ggml-good", contents: "weights", sha256: sha256("weights")))
        engine.load()

        let text = try await engine.transcribe([0.1]).text

        XCTAssertEqual(text, "ggml-good:1")
        XCTAssertEqual(engine.status, .ready)
    }

    func testVerifiedFilesAreNotRehashedUntilTheyChange() throws {
        let spec = modelFile("ggml-cached", contents: "weights")
        let cacheURL = dir.appendingPathComponent("checksums.json")
        var hashes = 0
        // A fresh verifier on the same sidecar stands in for the next launch.
        let nextLaunch = { ModelVerifier(cacheURL: cacheURL) { hashes += 1; return try ModelVerifier.sha256(of: $0) } }
        let good = sha256("weights")

        try nextLaunch().verify(path: spec.path, sha256: good)
        try nextLaunch().verify(path: spec.path, sha256: good)
        XCTAssertEqual(hashes, 1, "The sidecar spares a re-hash while size + date are unchanged")

        XCTAssertThrowsError(try nextLaunch().verify(path: spec.path, sha256: sha256("other")),
                             "A cached hash is still compared against the expected one")
        XCTAssertEqual(hashes, 1)

        FileManager.default.createFile(atPath: spec.path, contents: Data("swapped!".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: spec.path)
        XCTAssertThrowsError(try nextLaunch().verify(path: spec.path, sha256: good))
        XCTAssertEqual(hashes, 2, "A replaced file is hashed again")
    }

    // MARK: - Hot swap

    func testSwitchingModelsFinishesInFlightAndQueuedJobsOnTheOldModel() async throws {
        let a = modelFile("ggml-a"), b = modelFile("ggml-b")
        let gate = DispatchSemaphore(value: 0)
        factory.gates["ggml-a"] = gate
        let engine = makeEngine(a)
        engine.load()

        // Job 1 runs on A, held on the gate; job 2 queues behind it; then the
        // switch; then job 3.
        let job1 = Task { try await engine.transcribe([1]).text }
        await waitUntil("job 1 running") { factory.started == ["ggml-a"] }
        let job2 = Task { try await engine.transcribe([1, 1]).text }
        await waitUntil("job 2 queued") { engine.pendingJobCount == 2 }
        engine.switchModel(to: b)
        let job3 = Task { try await engine.transcribe([1, 1, 1]).text }
        await waitUntil("job 3 queued") { engine.pendingJobCount == 3 }
        gate.signal()
        gate.signal()

        let results = try await [job1.value, job2.value, job3.value]

        XCTAssertEqual(results, ["ggml-a:1", "ggml-a:2", "ggml-b:3"],
                       "Jobs submitted before the switch finish on the old model; later ones use the new one")
        XCTAssertEqual(factory.made, ["ggml-a", "ggml-b"])
        XCTAssertEqual(factory.freed, ["ggml-a"], "The old model is freed once its jobs are done")
        XCTAssertEqual(engine.status, .ready)
        XCTAssertEqual(engine.model, b)
    }

    func testSwitchingToTheSameModelIsANoOp() async throws {
        let a = modelFile("ggml-a")
        let engine = makeEngine(a)
        engine.load()
        _ = try await engine.transcribe([0.1])

        engine.switchModel(to: a)
        _ = try await engine.transcribe([0.1])

        XCTAssertEqual(factory.made, ["ggml-a"], "Re-applying the same settings doesn't reload")
    }

    func testSwitchingLanguageReloadsTheModel() async throws {
        var spec = modelFile("ggml-multi")
        let engine = makeEngine(spec)
        engine.load()
        _ = try await engine.transcribe([0.1])

        spec.language = "de"
        engine.switchModel(to: spec)
        _ = try await engine.transcribe([0.1])

        XCTAssertEqual(factory.made, ["ggml-multi", "ggml-multi"])
    }

    func testSwitchingToAMissingModelReportsMissing() async {
        let engine = makeEngine(modelFile("ggml-a"))
        let log = record(engine)
        engine.load()
        await waitUntil("ready") { engine.status == .ready }

        engine.switchModel(to: ModelSpec(path: dir.appendingPathComponent("nope.bin").path, sha256: nil, language: "en"))

        await waitUntil("missing reported") { log.seen.last == .missing }
        XCTAssertEqual(factory.freed, ["ggml-a"])
    }

    func testSwitchBeforeLoadJustChangesWhatLoadLoads() async throws {
        let engine = makeEngine(modelFile("ggml-a"))
        engine.switchModel(to: modelFile("ggml-b"))
        XCTAssertEqual(engine.status, .notLoaded)

        engine.load()
        let text = try await engine.transcribe([0.1]).text

        XCTAssertEqual(text, "ggml-b:1")
        XCTAssertEqual(factory.made, ["ggml-b"])
    }

    // MARK: - Idle unload

    func testIdleModelIsUnloadedAndReloadedTransparentlyOnTheNextJob() async throws {
        let engine = makeEngine(modelFile("ggml-a"), idleUnloadAfter: 0.05)
        let log = record(engine)
        engine.load()
        _ = try await engine.transcribe([0.1])

        await waitUntil("unloaded") { factory.freed == ["ggml-a"] }
        XCTAssertFalse(engine.isModelLoaded)
        XCTAssertEqual(engine.status, .ready, "An idle-unloaded engine still takes jobs")

        let text = try await engine.transcribe([0.1, 0.2]).text

        XCTAssertEqual(text, "ggml-a:2")
        XCTAssertEqual(factory.made, ["ggml-a", "ggml-a"])
        XCTAssertEqual(log.seen.filter { $0 == .loading }.count, 1, "The reload is silent: no status churn")
    }

    func testKeepWarmNeverUnloads() async throws {
        let engine = makeEngine(modelFile("ggml-a"), idleUnloadAfter: nil)
        engine.load()
        _ = try await engine.transcribe([0.1])
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(engine.isModelLoaded)
        XCTAssertEqual(factory.freed, [])
    }

    func testIdleUnloadCanBeTurnedOnAndOffLive() async throws {
        let engine = makeEngine(modelFile("ggml-a"), idleUnloadAfter: nil)
        engine.load()
        _ = try await engine.transcribe([0.1])

        engine.setIdleUnload(after: 0.05)
        await waitUntil("unloaded") { !engine.isModelLoaded }

        engine.setIdleUnload(after: nil)   // keep warm again: reloads in the background
        await waitUntil("reloaded") { engine.isModelLoaded }
        XCTAssertEqual(factory.made, ["ggml-a", "ggml-a"])
    }

    func testPrewarmReloadsAnIdleModelAheadOfTheJob() async throws {
        let engine = makeEngine(modelFile("ggml-a"), idleUnloadAfter: 0.05)
        engine.load()
        _ = try await engine.transcribe([0.1])
        await waitUntil("unloaded") { !engine.isModelLoaded }

        engine.prewarm()

        await waitUntil("reloaded") { engine.isModelLoaded }
        XCTAssertEqual(factory.made, ["ggml-a", "ggml-a"])
    }
}

/// Hex SHA-256 of in-memory bytes, for building expected checksums.
private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sha-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: data)
        defer { try? FileManager.default.removeItem(at: url) }
        return try! ModelVerifier.sha256(of: url)
    }
}
