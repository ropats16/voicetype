import XCTest
import ServiceManagement
@testable import VoiceType

/// The first load of a Core ML model on this Mac (WhisperKit, Parakeet):
/// Core ML specializes it for the Neural Engine, which takes a while, and
/// again after a macOS update. `ModelLoadHistory` remembers which models
/// loaded on which OS build, so readiness and Settings can say "Preparing
/// model for this Mac (first load, ~20 s)…" instead of a bare "Loading".
final class FirstLoadTests: XCTestCase {

    private var historyURL: URL!

    override func setUp() {
        super.setUp()
        historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-loads-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: historyURL)
        super.tearDown()
    }

    private let tiny = ModelSpec(path: "/m/whisperkit/tiny.en", sha256: nil, language: "en", engine: .whisperKit)
    private let base = ModelSpec(path: "/m/whisperkit/base.en", sha256: nil, language: "en", engine: .whisperKit)

    // MARK: - History

    func testAModelLoadedOnThisOSBuildIsRememberedAcrossLaunches() {
        let history = ModelLoadHistory(url: historyURL, osBuild: "25B78")
        XCTAssertFalse(history.hasLoaded(tiny))

        history.recordLoad(tiny)

        XCTAssertTrue(history.hasLoaded(tiny))
        XCTAssertFalse(history.hasLoaded(base), "per model")
        history.flush()
        XCTAssertTrue(ModelLoadHistory(url: historyURL, osBuild: "25B78").hasLoaded(tiny), "persisted")
    }

    /// The build (e.g. "25B78"), not the version string: a point update and
    /// a rapid security response each get their own build, so their own compile.
    func testTheOSBuildIsTheKernelsBuildNumber() {
        let build = ModelLoadHistory.currentOSBuild
        XCTAssertFalse(build.isEmpty)
        XCTAssertTrue(build.allSatisfy { $0.isLetter || $0.isNumber }, build)
        XCTAssertTrue(ProcessInfo.processInfo.operatingSystemVersionString.contains(build),
                      "\(ProcessInfo.processInfo.operatingSystemVersionString) names build \(build)")
    }

    /// macOS recompiles Core ML models after an update.
    func testAnOSUpdateMakesTheNextLoadAFirstLoadAgain() {
        let history = ModelLoadHistory(url: historyURL, osBuild: "25B78")
        history.recordLoad(tiny)
        history.flush()
        XCTAssertFalse(ModelLoadHistory(url: historyURL, osBuild: "25C56").hasLoaded(tiny))
    }

    func testTheLanguageDoesntMatter() {
        let history = ModelLoadHistory(url: historyURL, osBuild: "25B78")
        history.recordLoad(tiny)
        var german = tiny
        german.language = "de"
        XCTAssertTrue(history.hasLoaded(german), "the compiled model doesn't depend on it")
    }

    // MARK: - Which engines

    func testOnlyCoreMLEnginesHaveAFirstLoad() {
        let engines = EngineRegistry([WhisperEngine(), WhisperKitEngine(), ParakeetEngine()])
        let history = ModelLoadHistory(url: historyURL, osBuild: "25B78")
        let parakeet = ModelSpec(path: "/m/parakeet/p", sha256: nil, language: "en", engine: .parakeet)

        XCTAssertTrue(engines.isFirstLoad(tiny, history: history))
        XCTAssertTrue(engines.isFirstLoad(parakeet, history: history))
        XCTAssertFalse(engines.isFirstLoad(.file("/m/ggml-base.en.bin"), history: history), "whisper.cpp has no compile step")

        history.recordLoad(tiny)
        XCTAssertFalse(engines.isFirstLoad(tiny, history: history))
    }

    // MARK: - Readiness

    private func status(_ engine: TranscriptionStatus, firstLoad: Bool) -> AppStatus {
        AppReadiness.status(for: ReadinessInputs(
            accessibility: .granted, microphone: .authorized,
            engine: EngineReadiness(status: engine, modelPath: tiny.path, download: nil, isFirstLoad: firstLoad),
            hotkeyTap: .installed))
    }

    func testAFirstLoadSaysItsPreparingTheModel() {
        XCTAssertEqual(status(.loading, firstLoad: true), .starting(.modelPreparing))
        XCTAssertEqual(status(.notLoaded, firstLoad: true), .starting(.modelPreparing))
        XCTAssertEqual(status(.loading, firstLoad: false), .starting(.modelLoading))
        XCTAssertEqual(status(.verifying, firstLoad: true), .starting(.modelVerifying), "hashing comes first")
        XCTAssertEqual(status(.ready, firstLoad: true), .ready)

        XCTAssertEqual(ReadinessIssue.modelPreparing.detail, "Preparing model for this Mac (first load, ~20 s)…")
        XCTAssertEqual(ReadinessIssue.modelPreparing.title, "Preparing model…")
        XCTAssertTrue(AppStatus.starting(.modelPreparing).allowsDictation, "the job queues behind the load")
    }
}

/// Settings' model status line during a first load.
@MainActor
final class SettingsFirstLoadTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private func makeVM(firstLoad: Bool) -> SettingsViewModel {
        let store = ConfigStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-first-load-\(UUID().uuidString).json"))
        let vm = SettingsViewModel(
            configStore: store, loginItem: LoginItem(service: NoLoginItem()), availableMics: { [] },
            presentModelFilenames: { [] }, onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: HardwareProfile(isAppleSilicon: true, memoryBytes: 16 << 30),
            currentModel: { ModelSpec(path: "/m/whisperkit/tiny.en", sha256: nil, language: "en", engine: .whisperKit) },
            modelStatus: .loading, onModelSettingsChange: {},
            isFirstLoad: { _ in firstLoad })
        return vm
    }

    func testAFirstLoadSaysItsPreparingTheModel() {
        XCTAssertEqual(makeVM(firstLoad: true).modelStatusHint, "Preparing model for this Mac (first load, ~20 s)…")
        XCTAssertEqual(makeVM(firstLoad: false).modelStatusHint, "Loading model…")
    }
}
