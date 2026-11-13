import XCTest
import ServiceManagement
@testable import VoiceType

/// The Settings model section: picking a model (or Automatic), language, and
/// keep-warm — each persisted and applied live through `onModelSettingsChange`
/// — and showing what the engine really runs.
@MainActor
final class SettingsModelTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var applied = 0
    private var menuRefreshes = 0
    /// Stands in for the engine: what it runs. Like the app, it re-resolves
    /// the config each time settings are applied, unless a test overrides it.
    private var engineModel: ModelSpec!
    private var hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: 8 << 30)
    private var present: Set<String> = []

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-model-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        // whisper's model section; Automatic engine picks are SettingsEngineTests'.
        configStore.update { $0.engine = EngineKind.whisper.rawValue }
        applied = 0
        menuRefreshes = 0
        present = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func resolve() -> ModelSpec {
        ModelSelection.resolve(configStore.config, hardware: hardware, presentFilenames: present)
    }

    private func makeVM(present: Set<String> = [], gib: UInt64 = 8) -> SettingsViewModel {
        self.present = present
        hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: gib << 30)
        engineModel = resolve()
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { [unowned self] in self.present },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshes += 1 },
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: hardware,
            currentModel: { [unowned self] in self.engineModel },
            modelStatus: .ready,
            onModelSettingsChange: { [weak self] in
                guard let self else { return }
                self.applied += 1
                self.engineModel = self.resolve()
            }
        )
    }

    // MARK: - Model

    func testFreshConfigShowsAutomaticWithTheRecommendation() {
        let vm = makeVM(present: ["ggml-small.en-q5_1.bin"], gib: 8)
        XCTAssertEqual(vm.modelRow, .automatic)
        XCTAssertEqual(vm.recommendedModel.id, "small.en-q5_1")
        XCTAssertEqual(vm.automaticLabel, "Automatic (\(vm.recommendedModel.label))")
    }

    func testAutomaticNamesTheFallbackActuallyInUse() {
        let vm = makeVM(present: ["ggml-tiny.en.bin"], gib: 8)
        XCTAssertEqual(vm.automaticLabel, "Automatic — using tiny.en (small.en-q5_1 not downloaded)")
    }

    func testSelectingADownloadedModelPersistsItAndAppliesLive() {
        let vm = makeVM(present: ["ggml-base.en.bin"])

        vm.selectModel(.catalog("base.en"))

        XCTAssertEqual(configStore.config.model, .named("base.en"))
        XCTAssertEqual(configStore.config.modelPath, "", "A catalog pick clears any old explicit file path")
        XCTAssertEqual(vm.modelRow, .catalog("base.en"))
        XCTAssertEqual(applied, 1, "The engine is told to switch, no restart needed")
        XCTAssertGreaterThan(menuRefreshes, 0)
    }

    func testSelectingANotDownloadedModelIsIgnored() {
        let vm = makeVM(present: [])

        vm.selectModel(.catalog("medium.en"))

        XCTAssertEqual(configStore.config.model, .automatic)
        XCTAssertEqual(vm.modelRow, .automatic)
        XCTAssertEqual(applied, 0)
    }

    func testSelectingAutomaticClearsAnExplicitChoice() {
        configStore.update { $0.modelPath = "/m/ggml-medium.en.bin" }
        let vm = makeVM()
        XCTAssertEqual(vm.modelRow, .catalog("medium.en"), "An old config's modelPath shows as that model")

        vm.selectModel(.automatic)

        XCTAssertEqual(configStore.config.model, .automatic)
        XCTAssertEqual(configStore.config.modelPath, "")
        XCTAssertEqual(applied, 1)
    }

    func testACustomModelPathShowsAsCustomWithoutABogusDownloadHint() {
        configStore.update { $0.modelPath = "/m/finetune.bin" }
        let vm = makeVM()
        XCTAssertEqual(vm.modelRow, .custom)
        XCTAssertEqual(vm.customModelName, "finetune.bin")

        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Model file not found: /m/finetune.bin")
    }

    func testModelListsSplitDownloadedFromNot() {
        let vm = makeVM(present: ["ggml-tiny.en.bin", "ggml-small-q5_1.bin"])
        let lists = vm.modelLists
        XCTAssertEqual(lists.downloaded.map(\.id), ["tiny.en", "small-q5_1"])
        XCTAssertEqual(lists.notDownloaded.count, ModelCatalog.models.count - 2)
    }

    // MARK: - Language

    func testLanguageFollowsTheModelTheEngineRuns() {
        let vm = makeVM(present: ["ggml-small.en-q5_1.bin", "ggml-small-q5_1.bin"])
        XCTAssertFalse(vm.isLanguageSelectable, "auto-picked small.en-q5_1 is English-only")

        vm.selectModel(.catalog("small-q5_1"))
        XCTAssertTrue(vm.isLanguageSelectable)

        vm.setLanguage("de")
        XCTAssertEqual(configStore.config.language, "de")
        XCTAssertEqual(vm.language, "de")
        XCTAssertEqual(applied, 2)
    }

    // MARK: - Keep warm

    func testKeepWarmStartsAutomaticAndCanGoBackToIt() {
        let vm = makeVM(gib: 8)
        XCTAssertEqual(vm.keepWarm, .automatic)
        XCTAssertEqual(vm.label(for: .automatic), "Automatic (unload when idle on this Mac)")

        vm.setKeepWarm(.always)
        XCTAssertEqual(configStore.config.keepModelWarm, true)

        vm.setKeepWarm(.automatic)
        XCTAssertNil(configStore.config.keepModelWarm, "Back to automatic, not stuck on an explicit value")
        XCTAssertEqual(applied, 2)
    }

    func testAutomaticKeepWarmKeepsLoadedOnBiggerMacs() {
        XCTAssertEqual(makeVM(gib: 16).label(for: .automatic), "Automatic (keep loaded on this Mac)")
    }

    // MARK: - Status

    func testStatusHints() {
        let vm = makeVM(present: [])
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Not downloaded. Run: make model MODEL=small.en-q5_1")

        vm.modelStatusChanged(.verifying)
        XCTAssertEqual(vm.modelStatusHint, "Verifying the model's checksum (first use)…")

        vm.modelStatusChanged(.ready)
        XCTAssertNil(vm.modelStatusHint)
    }

    func testAFailedSwitchStaysVisibleAfterTheEngineFallsBack() {
        let vm = makeVM(present: ["ggml-tiny.en.bin"])
        vm.modelStatusChanged(.loading)
        vm.modelStatusChanged(.failed(reason: "Couldn't switch to x. Still using ggml-tiny.en.bin."))
        vm.modelStatusChanged(.ready)

        XCTAssertEqual(vm.modelStatusHint, "Couldn't switch to x. Still using ggml-tiny.en.bin.")

        vm.setLanguage("en")   // any settings change clears it
        XCTAssertNil(vm.modelStatusHint)
    }
}
