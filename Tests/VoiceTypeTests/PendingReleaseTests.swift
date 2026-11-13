import XCTest
@testable import VoiceType

/// Apple Speech's model release (`PendingRelease`): the adapter's deinit
/// mustn't block whoever drops it (possibly main), yet the next adapter's
/// setup must not be undone by a release still in flight.
final class PendingReleaseTests: XCTestCase {

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ event: String) { lock.withLock { _all.append(event) } }
    }

    func testReleaseReturnsAtOnceAndSetupWaitsForIt() async {
        let events = Events()
        let release = PendingRelease {
            try? await Task.sleep(nanoseconds: 300_000_000)
            events.add("released")
        }

        let start = Date()
        release.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "start() waited for the release")

        await release.settled()
        events.add("set up")
        XCTAssertEqual(events.all, ["released", "set up"])
    }

    func testSettledWithNothingPendingReturns() async {
        await PendingRelease {}.settled()
    }
}
