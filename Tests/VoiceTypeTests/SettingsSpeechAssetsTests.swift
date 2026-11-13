import XCTest
import ServiceManagement
@testable import VoiceType

/// Settings' model section for Apple Speech, whose model the OS manages: it
/// shows the asset state, downloads on request, and re-applies the model
/// settings when the download lands so the engine reloads. The OS is faked.
@MainActor
final class SettingsSpeechAssetsTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private final class FakeAssets: SpeechModelAssets, @unchecked Sendable {
        var state: AppleSpeechAssetState = .notInstalled
        var installError: Error?
        var installs: [String] = []
        /// Progress the install reports before finishing.
        var progressSteps: [Double] = []

        func state(language: String) async -> AppleSpeechAssetState { state }

        func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
            installs.append(language)
            progressSteps.forEach(progress)
            if let installError { throw installError }
            state = .installed
        }
    }

    private struct Offline: LocalizedError { var errorDescription: String? { "The network is offline." } }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var applied = 0
    private let assets = FakeAssets()
    private let environment = EngineEnvironment.mac(26)
    private lazy var engines = EngineRegistry([
        WhisperEngine(),
        AppleSpeechEngine(transcriberAvailable: { true }, assetState: { [assets] _ in assets.state }),
    ])

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-speech-assets-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        applied = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeVM(engine: EngineKind = .appleSpeech) -> SettingsViewModel {
        configStore.update {
            $0.engine = engine.rawValue
            $0.language = "en"
        }
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { .appleSpeech(language: "en") },
            modelStatus: .missing,
            onModelSettingsChange: { [weak self] in self?.applied += 1 },
            engines: engines,
            environment: environment,
            speechAssets: assets
        )
    }

    func testWhispersSectionShowsNoAssetState() async {
        let vm = makeVM(engine: .whisper)
        await vm.refreshSpeechAssets()
        XCTAssertNil(vm.speechAssetLabel)
        XCTAssertFalse(vm.canDownloadSpeechModel)
    }

    func testShowsWhetherTheModelIsDownloaded() async {
        let vm = makeVM()
        await vm.refreshSpeechAssets()
        XCTAssertEqual(vm.speechAssetLabel, "Not downloaded")
        XCTAssertTrue(vm.canDownloadSpeechModel)

        assets.state = .installed
        await vm.refreshSpeechAssets()
        XCTAssertEqual(vm.speechAssetLabel, "Downloaded")
        XCTAssertFalse(vm.canDownloadSpeechModel)
    }

    func testShowsDownloadProgress() async {
        let vm = makeVM()
        assets.state = .downloading(progress: 0.42)
        await vm.refreshSpeechAssets()
        XCTAssertEqual(vm.speechAssetLabel, "Downloading… 42%")
        XCTAssertFalse(vm.canDownloadSpeechModel)

        assets.state = .downloading(progress: nil)
        await vm.refreshSpeechAssets()
        XCTAssertEqual(vm.speechAssetLabel, "Downloading…")
    }

    func testAnUnsupportedLanguageSaysSo() async {
        let vm = makeVM()
        assets.state = .unsupported
        await vm.refreshSpeechAssets()
        XCTAssertEqual(vm.speechAssetLabel, "Not available for English on this Mac")
        XCTAssertFalse(vm.canDownloadSpeechModel)
    }

    /// The download lands, then the model settings are re-applied once so the
    /// engine (reporting `.missing`) loads the model.
    func testDownloadingInstallsThenReloadsTheEngine() async {
        let vm = makeVM()
        await vm.refreshSpeechAssets()
        assets.progressSteps = [0.25, 0.8]

        await vm.downloadSpeechModel()

        XCTAssertEqual(assets.installs, ["en"])
        XCTAssertEqual(vm.speechAssetLabel, "Downloaded")
        XCTAssertNil(vm.speechAssetError)
        XCTAssertEqual(applied, 1)
    }

    func testAFailedDownloadSaysWhyAndChangesNothing() async {
        let vm = makeVM()
        await vm.refreshSpeechAssets()
        assets.installError = Offline()

        await vm.downloadSpeechModel()

        XCTAssertEqual(vm.speechAssetError, "Download failed: The network is offline.")
        XCTAssertEqual(vm.speechAssetLabel, "Not downloaded")
        XCTAssertTrue(vm.canDownloadSpeechModel)
        XCTAssertEqual(applied, 0)
    }

    func testDownloadIsOnlyOfferedWhenNeeded() async {
        let vm = makeVM()
        assets.state = .installed
        await vm.refreshSpeechAssets()

        await vm.downloadSpeechModel()

        XCTAssertEqual(assets.installs, [])
        XCTAssertEqual(applied, 0)
    }
}
