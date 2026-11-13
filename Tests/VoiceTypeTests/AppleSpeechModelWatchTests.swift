import XCTest
@testable import VoiceType

/// Apple Speech's model can be installed outside Settings (by the OS, or
/// another app). While the engine reports it missing, the watch re-asks the
/// OS and reloads once it's there. The OS is faked.
@MainActor
final class AppleSpeechModelWatchTests: XCTestCase {

    private final class FakeAssets: SpeechModelAssets, @unchecked Sendable {
        private let lock = NSLock()
        private var _state: AppleSpeechAssetState = .notInstalled
        private var _queries: [String] = []
        var state: AppleSpeechAssetState {
            get { lock.withLock { _state } }
            set { lock.withLock { _state = newValue } }
        }
        var queries: [String] { lock.withLock { _queries } }

        func state(language: String) async -> AppleSpeechAssetState {
            lock.withLock { _queries.append(language); return _state }
        }
        func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    }

    private let assets = FakeAssets()
    private var missing: ModelSpec? = .appleSpeech(language: "de")
    private var reloads = 0

    private func makeWatch() -> AppleSpeechModelWatch {
        AppleSpeechModelWatch(assets: assets, missingModel: { [unowned self] in missing },
                              reload: { [unowned self] in reloads += 1 })
    }

    /// Lets the watch's query and its hop back to main run.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testReloadsOnceTheMissingModelIsInstalled() async {
        let watch = makeWatch()

        watch.check()
        await settle()
        XCTAssertEqual(reloads, 0, "Still not installed")
        XCTAssertEqual(assets.queries, ["de"])

        assets.state = .installed
        watch.check()
        await settle()
        XCTAssertEqual(reloads, 1)
    }

    func testDownloadingIsNotInstalledYet() async {
        assets.state = .downloading(progress: nil)
        let watch = makeWatch()
        watch.check()
        await settle()
        XCTAssertEqual(reloads, 0)
    }

    func testDoesNotAskTheOSUnlessAnAppleModelIsMissing() async {
        missing = nil
        assets.state = .installed
        let watch = makeWatch()
        watch.check()
        await settle()
        XCTAssertEqual(assets.queries, [])
        XCTAssertEqual(reloads, 0)
    }

    /// The engine moved on meanwhile (another model, or it already loaded):
    /// the answer is stale, so no reload.
    func testNoReloadIfTheModelIsNoLongerMissingWhenTheAnswerComes() async {
        assets.state = .installed
        let watch = makeWatch()
        watch.check()
        missing = nil
        await settle()
        XCTAssertEqual(reloads, 0)
    }
}
