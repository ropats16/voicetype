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
