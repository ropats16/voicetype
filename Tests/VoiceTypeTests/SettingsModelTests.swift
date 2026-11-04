import XCTest
import ServiceManagement
@testable import VoiceType

/// The Settings model section: picking a model (or Automatic), language, and
/// keep-warm — each persisted and applied live through `onModelSettingsChange`.
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

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-model-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        applied = 0
        menuRefreshes = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeVM(present: Set<String> = [], gib: UInt64 = 8) -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { present },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshes += 1 },
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: HardwareProfile(isAppleSilicon: true, memoryBytes: gib << 30),
            onModelSettingsChange: { [weak self] in self?.applied += 1 }
        )
    }

    // MARK: - Model

    func testFreshConfigShowsAutomaticWithTheRecommendation() {
        let vm = makeVM(gib: 8)
        XCTAssertEqual(vm.selectedModelID, ModelSelection.automatic)
        XCTAssertEqual(vm.recommendedModel.id, "small.en-q5_1")
    }

    func testSelectingADownloadedModelPersistsItAndAppliesLive() {
        let vm = makeVM(present: ["ggml-base.en.bin"])

        vm.selectModel("base.en")

        XCTAssertEqual(configStore.config.model, "base.en")
        XCTAssertEqual(configStore.config.modelPath, "", "A catalog pick clears any old explicit file path")
        XCTAssertEqual(vm.selectedModelID, "base.en")
        XCTAssertEqual(applied, 1, "The engine is told to switch, no restart needed")
        XCTAssertGreaterThan(menuRefreshes, 0)
    }

    func testSelectingANotDownloadedModelIsIgnored() {
        let vm = makeVM(present: [])

        vm.selectModel("medium.en")

        XCTAssertEqual(configStore.config.model, ModelSelection.automatic)
        XCTAssertEqual(vm.selectedModelID, ModelSelection.automatic)
        XCTAssertEqual(applied, 0)
    }

    func testSelectingAutomaticClearsAnExplicitChoice() {
        configStore.update { $0.modelPath = "/m/ggml-medium.en.bin" }
        let vm = makeVM()
        XCTAssertEqual(vm.selectedModelID, "medium.en", "An old config's modelPath shows as that model")

        vm.selectModel(ModelSelection.automatic)

        XCTAssertEqual(configStore.config.model, ModelSelection.automatic)
        XCTAssertEqual(configStore.config.modelPath, "")
        XCTAssertEqual(applied, 1)
    }

    func testACustomModelPathShowsAsCustom() {
        configStore.update { $0.modelPath = "/m/finetune.bin" }
        let vm = makeVM()
        XCTAssertEqual(vm.selectedModelID, SettingsViewModel.customModelID)
        XCTAssertEqual(vm.customModelName, "finetune.bin")
    }

    func testModelListSplitsDownloadedFromNot() {
        let vm = makeVM(present: ["ggml-tiny.en.bin", "ggml-small-q5_1.bin"])
        XCTAssertEqual(vm.downloadedModels.map(\.id), ["tiny.en", "small-q5_1"])
        XCTAssertEqual(vm.notDownloadedModels.count, ModelCatalog.models.count - 2)
    }

    // MARK: - Language

    func testLanguageIsLockedToEnglishForEnglishOnlyModels() {
        let vm = makeVM(present: ["ggml-small.en-q5_1.bin", "ggml-small-q5_1.bin"])
        XCTAssertFalse(vm.isLanguageSelectable, "auto-picked small.en-q5_1 is English-only")

        vm.selectModel("small-q5_1")
        XCTAssertTrue(vm.isLanguageSelectable)

        vm.setLanguage("de")
        XCTAssertEqual(configStore.config.language, "de")
        XCTAssertEqual(vm.language, "de")
        XCTAssertEqual(applied, 2)
    }

    // MARK: - Keep warm

    func testKeepWarmShowsTheAutomaticDefaultForThisMac() {
        XCTAssertFalse(makeVM(gib: 8).keepModelWarm, "8 GB unloads when idle by default")
        XCTAssertTrue(makeVM(gib: 16).keepModelWarm)
    }

    func testSettingKeepWarmPersistsAnExplicitChoice() {
        let vm = makeVM(gib: 8)

        vm.setKeepModelWarm(true)

        XCTAssertEqual(configStore.config.keepModelWarm, true)
        XCTAssertTrue(vm.keepModelWarm)
        XCTAssertEqual(applied, 1)
    }

    // MARK: - Status

    func testStatusHintNamesTheDownloadCommandWhenMissing() {
        let vm = makeVM(present: [])
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Not downloaded. Run: make model MODEL=small.en-q5_1")

        vm.modelStatusChanged(.failed(reason: "bad file"))
        XCTAssertEqual(vm.modelStatusHint, "Failed to load: bad file")

        vm.modelStatusChanged(.ready)
        XCTAssertNil(vm.modelStatusHint)
    }
}
