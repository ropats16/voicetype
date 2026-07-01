import XCTest
@testable import VoiceType

/// Tests for the pure clipboard-restore coordination layer (Phase 3, Task 3):
/// deciding when an `insert()` call should capture a fresh origin snapshot,
/// and whether a since-superseded scheduled restore should actually fire.
/// Driven with synthetic `beginInsert()`/`restoreFired(_:)` call sequences —
/// no real `NSPasteboard` or `Timer` involved.
final class RestoreSchedulerTests: XCTestCase {

    // MARK: - Single insert

    func testSingleInsertCapturesOriginAndRestoreFires() {
        var scheduler = RestoreScheduler()

        let (shouldCapture, token) = scheduler.beginInsert()
        XCTAssertTrue(shouldCapture, "The first insert of a burst must capture a fresh origin snapshot")

        XCTAssertTrue(scheduler.restoreFired(token),
                      "The only scheduled restore in a burst must actually fire")
    }

    // MARK: - Two rapid inserts: second reuses origin, only second's restore fires

    func testSecondRapidInsertReusesOriginAndSupersedesFirstRestore() {
        var scheduler = RestoreScheduler()

        let (firstShouldCapture, firstToken) = scheduler.beginInsert()
        XCTAssertTrue(firstShouldCapture)

        let (secondShouldCapture, secondToken) = scheduler.beginInsert()
        XCTAssertFalse(secondShouldCapture,
                       "A second insert arriving while a restore is still pending must reuse the first insert's origin snapshot, not capture a new one")
        XCTAssertNotEqual(firstToken, secondToken, "Each insert must get its own distinct token")

        XCTAssertFalse(scheduler.restoreFired(firstToken),
                       "The first insert's restore must be superseded and must not actually restore")
        XCTAssertTrue(scheduler.restoreFired(secondToken),
                      "The second (most recent) insert's restore must actually fire")
    }

    // MARK: - Fresh burst after a prior restore already fired

    func testInsertAfterPriorRestoreFiredStartsFreshBurst() {
        var scheduler = RestoreScheduler()

        let (_, firstToken) = scheduler.beginInsert()
        XCTAssertTrue(scheduler.restoreFired(firstToken), "First burst's restore fires normally")

        let (secondShouldCapture, secondToken) = scheduler.beginInsert()
        XCTAssertTrue(secondShouldCapture,
                      "Once the prior restore has already fired, a new insert starts a fresh burst and must capture a new origin snapshot")
        XCTAssertTrue(scheduler.restoreFired(secondToken))
    }

    // MARK: - Three rapid inserts collapse to one restore

    func testThreeRapidInsertsCollapseToOneRestore() {
        var scheduler = RestoreScheduler()

        let (firstShouldCapture, firstToken) = scheduler.beginInsert()
        XCTAssertTrue(firstShouldCapture)

        let (secondShouldCapture, secondToken) = scheduler.beginInsert()
        XCTAssertFalse(secondShouldCapture)

        let (thirdShouldCapture, thirdToken) = scheduler.beginInsert()
        XCTAssertFalse(thirdShouldCapture,
                       "A third insert in the same burst must also reuse the original origin snapshot")

        // Timers can fire in scheduled order (first, then second, then third).
        XCTAssertFalse(scheduler.restoreFired(firstToken))
        XCTAssertFalse(scheduler.restoreFired(secondToken))
        XCTAssertTrue(scheduler.restoreFired(thirdToken),
                      "Only the last-scheduled restore in the burst must actually fire")
    }

    // MARK: - A stale token fired twice only succeeds once

    func testRestoreFiredIsNotRepeatableForTheSameToken() {
        var scheduler = RestoreScheduler()

        let (_, token) = scheduler.beginInsert()
        XCTAssertTrue(scheduler.restoreFired(token))
        XCTAssertFalse(scheduler.restoreFired(token),
                       "A restore token must not be able to fire a second time")
    }
}
