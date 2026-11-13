import XCTest
@testable import VoiceType

/// Tests for `TranscriptionEngine` through its interface, driven by a fake
/// adapter in place of whisper.cpp — no model, no Metal.
final class TranscriptionEngineTests: XCTestCase {

    // MARK: - Fake adapter

    /// Stands in for whisper.cpp: records every job it runs and returns one
    /// segment naming the sample count, after an optional delay.
    private final class FakeAdapter: TranscriptionAdapter {
        var delay: TimeInterval = 0
        private let lock = NSLock()
        private var _jobs: [[Float]] = []
        private var inFlight = 0
        private var _maxInFlight = 0

        var jobs: [[Float]] { lock.withLock { _jobs } }
        var maxInFlight: Int { lock.withLock { _maxInFlight } }

        func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
            lock.withLock {
                _jobs.append(samples)
                inFlight += 1
                _maxInFlight = max(_maxInFlight, inFlight)
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.withLock { inFlight -= 1 }
            return [Transcript.Segment(text: " \(samples.count) samples", start: 0, end: 1)]
        }
    }

    private struct FakeError: LocalizedError {
        var errorDescription: String? { "fake load failure" }
    }

    // MARK: - Test state

    private var modelURL: URL!
    private var fake: FakeAdapter!

    override func setUp() {
        super.setUp()
        // A real (empty) file so the engine sees the model as present; the fake
        // adapter never reads it.
        modelURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        fake = FakeAdapter()
    }

    private func makeEngine() -> TranscriptionEngine {
        TranscriptionEngine(model: .at(modelURL.path), makeAdapter: { [fake] _ in fake! })
    }

    /// Calls `load()` and waits for the engine to settle, returning every status
    /// it reported along the way (delivered on main).
    private func loadAndWait(_ engine: TranscriptionEngine) async -> [TranscriptionStatus] {
        var seen: [TranscriptionStatus] = []
        let settled = expectation(description: "engine settled")
        engine.onStatusChange = { status in
            seen.append(status)
            if status != .loading { settled.fulfill() }
        }
        engine.load()
        await fulfillment(of: [settled], timeout: 5)
        return seen
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelURL)
        super.tearDown()
    }

    // MARK: - Status

    func testMissingModelFileReportsMissing() async {
        let engine = TranscriptionEngine(model: .at("/nonexistent/ggml-none.bin"),
                                         makeAdapter: { _ in XCTFail("must not load a missing model"); throw FakeError() })

        let seen = await loadAndWait(engine)

        XCTAssertEqual(seen, [.missing], "No model file is reported as missing, without trying to load")
    }

    /// The presence check may be slow (Apple's asks the OS), and `load()` is
    /// called on main: it must return at once and check on the engine's queue.
    func testLoadChecksPresenceOffTheCallingThread() async {
        let engine = TranscriptionEngine(model: .at(modelURL.path),
                                         isPresent: { _ in Thread.sleep(forTimeInterval: 0.5); return false },
                                         makeAdapter: { _ in XCTFail("must not load a missing model"); throw FakeError() })
        var seen: [TranscriptionStatus] = []
        let settled = expectation(description: "engine settled")
        engine.onStatusChange = { seen.append($0); settled.fulfill() }

        let start = Date()
        engine.load()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "load() waited for the presence check")

        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(seen, [.missing])
    }

    func testLoadMovesFromNotLoadedThroughLoadingToReady() async {
        let engine = makeEngine()
        XCTAssertEqual(engine.status, .notLoaded, "Nothing is loaded before load()")

        let seen = await loadAndWait(engine)

        XCTAssertEqual(seen, [.loading, .ready])
        XCTAssertEqual(engine.status, .ready)
    }

    func testLoadErrorReportsFailedNotMissing() async {
        let engine = TranscriptionEngine(model: .at(modelURL.path), makeAdapter: { _ in throw FakeError() })

        let seen = await loadAndWait(engine)

        XCTAssertEqual(seen, [.loading, .failed(reason: "fake load failure")],
                       "A model file that exists but won't load is a failure, not a missing model")
    }

    // MARK: - Warm-up

    func testOneSecondOfSilenceIsTranscribedOnceBeforeReady() async throws {
        let engine = makeEngine()
        _ = await loadAndWait(engine)

        XCTAssertEqual(fake.jobs.map(\.count), [16_000],
                       "Load must run exactly one 1 s (16 kHz) warm-up before reporting ready")
        XCTAssertTrue(fake.jobs.first?.allSatisfy { $0 == 0 } ?? false, "The warm-up clip is silence")

        _ = try await engine.transcribe([0.5])
        _ = try await engine.transcribe([0.5])
        XCTAssertEqual(fake.jobs.count, 3, "Warm-up runs once per load, not per job")
    }

    // MARK: - Jobs

    func testTranscribeReturnsTheAdaptersSegmentsAndJoinedText() async throws {
        let engine = makeEngine()
        _ = await loadAndWait(engine)

        let transcript = try await engine.transcribe([0.1, 0.2, 0.3])

        XCTAssertEqual(transcript.segments, [Transcript.Segment(text: " 3 samples", start: 0, end: 1)])
        XCTAssertEqual(transcript.text, " 3 samples")
    }

    func testConcurrentJobsRunOneAtATime() async throws {
        let engine = makeEngine()
        _ = await loadAndWait(engine)
        fake.delay = 0.02

        let texts = try await withThrowingTaskGroup(of: String.self) { group in
            for n in 1...5 {
                group.addTask { try await engine.transcribe([Float](repeating: 0.1, count: n)).text }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }

        XCTAssertEqual(fake.maxInFlight, 1, "Jobs submitted concurrently must never overlap in the adapter")
        XCTAssertEqual(texts, Set((1...5).map { " \($0) samples" }), "Each job gets its own result")
    }

    // MARK: - Jobs before ready

    func testJobSubmittedWhileLoadingWaitsForTheLoad() async throws {
        let engine = TranscriptionEngine(model: .at(modelURL.path), makeAdapter: { [fake] _ in
            Thread.sleep(forTimeInterval: 0.1)
            return fake!
        })
        engine.load()
        XCTAssertNotEqual(engine.status, .ready, "load() returns before the model is loaded")

        let transcript = try await engine.transcribe([0.1, 0.2])

        XCTAssertEqual(transcript.text, " 2 samples")
        XCTAssertEqual(engine.status, .ready)
    }

    func testJobWithoutALoadedModelThrowsModelNotLoaded() async {
        let neverLoaded = makeEngine()
        let missing = TranscriptionEngine(model: .at("/nonexistent/ggml-none.bin"), makeAdapter: { _ in throw FakeError() })
        missing.load()
        let failed = TranscriptionEngine(model: .at(modelURL.path), makeAdapter: { _ in throw FakeError() })
        _ = await loadAndWait(failed)

        for (name, engine) in [("never loaded", neverLoaded), ("missing", missing), ("failed", failed)] {
            do {
                _ = try await engine.transcribe([0.1])
                XCTFail("\(name): expected modelNotLoaded")
            } catch TranscriptionError.modelNotLoaded {
                // expected
            } catch {
                XCTFail("\(name): unexpected error \(error)")
            }
        }
    }
}

private extension ModelSpec {
    /// An unverified file, as these lifecycle tests need no checksum.
    static func at(_ path: String) -> ModelSpec { ModelSpec(path: path, sha256: nil, language: "en") }
}
