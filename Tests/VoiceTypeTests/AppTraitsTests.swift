import XCTest
import ApplicationServices
@testable import VoiceType

/// What the focus probe remembers per app process: Chromium detection, the
/// `AXManualAccessibility` opt-in retry policy, and the pid cache. The AX
/// calls themselves aren't unit-testable.
final class AppTraitsTests: XCTestCase {

    // MARK: - Chromium

    func testChromiumHostedFromBundledFrameworks() {
        let chromium: [[String]] = [
            ["Electron Framework.framework", "Mantle.framework", "Squirrel.framework"],   // VS Code, Slack
            ["Google Chrome Framework.framework"],
            ["Microsoft Edge Framework.framework"],
            ["Brave Browser Framework.framework"],
            ["Chromium Embedded Framework.framework"],                                  // CEF apps
        ]
        for frameworks in chromium {
            XCTAssertTrue(AppTraits.isChromiumHosted(frameworks: frameworks), "\(frameworks)")
        }
        let native: [[String]] = [
            [],
            ["Sparkle.framework", "Sentry.framework"],
            ["Electron.framework"],   // not the Electron Framework bundle name
        ]
        for frameworks in native {
            XCTAssertFalse(AppTraits.isChromiumHosted(frameworks: frameworks), "\(frameworks)")
        }
    }

    // MARK: - Opt-in

    private func fresh() -> AppTraits { AppTraits(launchDate: nil, isChromiumHosted: true) }

    func testOptInDueUntilSent() {
        XCTAssertTrue(fresh().needsOptIn(now: 0))
    }

    func testOptInSettlesOnSuccessOrUnsupported() {
        for result in [AXError.success, .attributeUnsupported] {
            var traits = fresh()
            traits.recordOptIn(result, now: 0)
            XCTAssertFalse(traits.needsOptIn(now: 0), "\(result.rawValue)")
            XCTAssertFalse(traits.needsOptIn(now: 1_000_000), "\(result.rawValue): once per process")
        }
    }

    func testOptInRetriedNextProbeWhenAccessibilityNotGranted() {
        // Before the user grants Accessibility every AX call fails fast with
        // apiDisabled; that must not latch the app as opted in.
        var traits = fresh()
        traits.recordOptIn(.apiDisabled, now: 0)
        XCTAssertTrue(traits.needsOptIn(now: 0))
        traits.recordOptIn(.success, now: 1)
        XCTAssertFalse(traits.needsOptIn(now: 1))
    }

    func testOtherFastErrorsAreRetriedNextProbe() {
        for result in [AXError.failure, .illegalArgument, .notImplemented, .invalidUIElement] {
            var traits = fresh()
            traits.recordOptIn(result, now: 0)
            XCTAssertTrue(traits.needsOptIn(now: 0), "\(result.rawValue)")
        }
    }

    func testTimedOutOptInBacksOff() {
        let wait = AppTraits.timedOutRetryInterval
        var traits = fresh()
        traits.recordOptIn(.cannotComplete, now: 100)
        XCTAssertFalse(traits.needsOptIn(now: 100), "A hung app isn't charged the timeout on every delivery")
        XCTAssertFalse(traits.needsOptIn(now: 100 + wait - 1))
        XCTAssertTrue(traits.needsOptIn(now: 100 + wait))

        traits.recordOptIn(.cannotComplete, now: 100 + wait)
        XCTAssertFalse(traits.needsOptIn(now: 100 + wait + 1), "Each timeout restarts the wait")
    }

    // MARK: - Cache

    private let launched = Date(timeIntervalSince1970: 1_000)

    func testCacheHitsTheSameProcess() {
        var cache = AppTraitsCache()
        var traits = AppTraits(launchDate: launched, isChromiumHosted: true)
        traits.recordOptIn(.success, now: 0)
        cache.store(traits, pid: 42)
        XCTAssertEqual(cache.traits(pid: 42, launchDate: launched), traits)
        XCTAssertNil(cache.traits(pid: 43, launchDate: launched))
    }

    func testReusedPidGetsFreshTraits() {
        var cache = AppTraitsCache()
        cache.store(AppTraits(launchDate: launched, isChromiumHosted: true), pid: 42)
        XCTAssertNil(cache.traits(pid: 42, launchDate: launched.addingTimeInterval(60)),
                     "Another process now has pid 42")
    }

    func testEvictedOnTermination() {
        var cache = AppTraitsCache()
        cache.store(AppTraits(launchDate: launched, isChromiumHosted: false), pid: 42)
        cache.store(AppTraits(launchDate: launched, isChromiumHosted: false), pid: 7)
        cache.evict(pid: 42)
        XCTAssertNil(cache.traits(pid: 42, launchDate: launched))
        XCTAssertEqual(cache.count, 1, "Bounded by running apps")
    }
}
