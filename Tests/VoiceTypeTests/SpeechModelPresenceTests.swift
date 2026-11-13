import XCTest
@testable import VoiceType

/// Automatic asks on main whether Apple Speech's model is installed; the OS
/// query blocks, so the app keeps the last answer per language and refreshes
/// it in the background, re-resolving only when the answer changes. The OS is
/// faked.
@MainActor
final class SpeechModelPresenceTests: XCTestCase {

    private final class FakeAssets: SpeechModelAssets, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [String: AppleSpeechAssetState] = [:]
        func set(_ state: AppleSpeechAssetState, for language: String) { lock.withLock { _states[language] = state } }
        func state(language: String) async -> AppleSpeechAssetState {
            lock.withLock { _states[language] ?? .notInstalled }
        }
        func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    }

    private func refresh(_ presence: SpeechModelPresence, _ language: String) async -> Bool {
        await withCheckedContinuation { done in presence.refresh(language: language) { done.resume(returning: $0) } }
    }

    func testUnknownUntilRefreshedThenTheLastAnswer() async {
        let assets = FakeAssets()
        assets.set(.installed, for: "ja")
        let presence = SpeechModelPresence(assets: assets)
        XCTAssertFalse(presence.isInstalled(language: "ja"), "Never asked: not installed (never a download)")
        XCTAssertFalse(presence.isKnown(language: "ja"))

        let changed = await refresh(presence, "ja")
        XCTAssertTrue(changed)
        XCTAssertTrue(presence.isKnown(language: "ja"))
        XCTAssertTrue(presence.isInstalled(language: "ja"))
        XCTAssertFalse(presence.isInstalled(language: "ko"), "Per language")

        let again = await refresh(presence, "ja")
        XCTAssertFalse(again, "Same answer: nothing to re-resolve")
    }

    func testOnlyAnInstalledModelCounts() async {
        let assets = FakeAssets()
        let presence = SpeechModelPresence(assets: assets)
        for state in [AppleSpeechAssetState.notInstalled, .downloading(progress: 0.5), .unsupported] {
            assets.set(state, for: "de")
            _ = await refresh(presence, "de")
            XCTAssertFalse(presence.isInstalled(language: "de"), "\(state)")
        }
        assets.set(.installed, for: "de")
        let changed = await refresh(presence, "de")
        XCTAssertTrue(changed)
        XCTAssertTrue(presence.isInstalled(language: "de"))
    }
}
