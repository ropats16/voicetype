import XCTest
@testable import VoiceType

final class BlockingAsyncTests: XCTestCase {

    func testReturnsTheWorksResult() throws {
        let value = try BlockingAsync.run(timeout: 5) {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func testRethrowsTheWorksError() {
        struct Boom: Error {}
        XCTAssertThrowsError(try BlockingAsync.run(timeout: 5) { () async throws -> Int in throw Boom() }) {
            XCTAssertTrue($0 is Boom)
        }
    }

    func testGivesUpAtTheDeadlineAndCancelsTheWork() {
        let cancelled = expectation(description: "work cancelled")
        let start = Date()
        XCTAssertThrowsError(try BlockingAsync.run(timeout: 0.1) { () async throws -> Int in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { cancelled.fulfill(); throw error }
            return 0
        }) { XCTAssertTrue($0 is BlockingAsync.TimedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        wait(for: [cancelled], timeout: 2)
    }
}

/// An adapter's bridge (`BlockingAsync.Bridge`): after a call times out, the
/// work it gave up on may still be using the engine, so later calls are
/// refused until that work has wound down — never two at once.
final class BlockingAsyncBridgeTests: XCTestCase {

    /// Work that ignores cancellation and runs until `release()`.
    private final class Stuck: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        func run() async { await withCheckedContinuation { c in DispatchQueue.global().async { self.gate.wait(); c.resume() } } }
        func release() { gate.signal() }
    }

    func testRunsWorkLikeBlockingAsync() throws {
        let bridge = BlockingAsync.Bridge(name: "Fake")
        XCTAssertEqual(try bridge.run(timeout: 5) { 7 }, 7)
        XCTAssertEqual(try bridge.run(timeout: 5) { 8 }, 8)
    }

    func testRefusesCallsWhileTimedOutWorkStillRunsThenRecovers() throws {
        let bridge = BlockingAsync.Bridge(name: "Fake")
        let stuck = Stuck()
        XCTAssertThrowsError(try bridge.run(timeout: 0.05) { await stuck.run() }) {
            XCTAssertTrue($0 is BlockingAsync.TimedOut)
        }

        let ran = Flag()
        XCTAssertThrowsError(try bridge.run(timeout: 5) { ran.set() }) {
            XCTAssertEqual(($0 as? BlockingAsync.StillBusy)?.name, "Fake")
            XCTAssertNotNil(($0 as? LocalizedError)?.errorDescription)
        }
        XCTAssertFalse(ran.value, "Refused without starting the work")

        stuck.release()
        let deadline = Date().addingTimeInterval(2)
        while bridge.isBusy && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(try bridge.run(timeout: 5) { 9 }, 9, "Usable again once the abandoned work ended")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }
}
