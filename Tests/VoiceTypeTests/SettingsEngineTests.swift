import XCTest
import ServiceManagement
@testable import VoiceType

/// The Settings engine picker, with a fake second engine registered beside
/// whisper: which engines are offered, picking one (persisted, applied live),
/// its own model list, and the whisper fallback when the language rules it out.
@MainActor
final class SettingsEngineTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var applied = 0
    private var engineModel: ModelSpec!
    private let environment = EngineEnvironment.mac(15, gib: 8)

    private func fakePath(_ id: String) -> String { Paths.modelsDir.appendingPathComponent("fake-\(id)").path }

    private lazy var engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [fakePath("fast")])])

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-engine-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        applied = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func resolve() -> ModelSpec {
        ModelSelection.select(configStore.config, environment: environment, engines: engines,
                              presentFilenames: ["ggml-small.en-q5_1.bin"]).spec
    }

    private func makeVM() -> SettingsViewModel {
        engineModel = resolve()
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { ["ggml-small.en-q5_1.bin"] },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { [unowned self] in self.engineModel },
            modelStatus: .ready,
            onModelSettingsChange: { [weak self] in
                guard let self else { return }
                self.applied += 1
                self.engineModel = self.resolve()
            },
            engines: engines,
            environment: environment
        )
    }

    func testAFreshConfigRunsWhisperAndOffersEveryEngineForTheLanguage() {
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.engineChoices, [.whisper, .parakeet])
        XCTAssertNil(vm.engineNote)
    }

    func testPickingAnEngineSavesItAndSwitchesLiveToItsModel() {
        let vm = makeVM()

        vm.selectEngine(.parakeet)

        XCTAssertEqual(configStore.config.engine, "parakeet")
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(engineModel, ModelSpec(path: fakePath("fast"), sha256: nil, language: "en", engine: .parakeet))
        XCTAssertEqual(vm.modelRow, .automatic)
        XCTAssertEqual(vm.automaticLabel, "Automatic (Fast)")
        XCTAssertEqual(vm.modelLists.downloaded.map(\.id), ["fast"])
        XCTAssertEqual(vm.modelLists.notDownloaded.map(\.id), ["big"])
        XCTAssertTrue(vm.isLanguageSelectable)
    }

    func testAModelPickIsKeptPerEngine() {
        configStore.update { $0.engine = "parakeet" }
        let vm = makeVM()

        vm.selectModel(.catalog("big"))
        XCTAssertEqual(applied, 0, "Not downloaded: can't be picked")

        vm.selectModel(.catalog("fast"))
        XCTAssertEqual(configStore.config.engineModels, ["parakeet": .named("fast")])
        XCTAssertEqual(configStore.config.model, .automatic, "whisper's pick is untouched")
        XCTAssertEqual(vm.modelRow, .catalog("fast"))
        XCTAssertEqual(applied, 1)

        vm.selectEngine(.whisper)
        XCTAssertEqual(vm.modelRow, .automatic, "whisper shows its own pick")
        XCTAssertEqual(engineModel.engine, .whisper)
    }

    func testALanguageTheEngineCantDoFallsBackToWhisperUntilItCan() {
        configStore.update { $0.engine = "parakeet" }
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .parakeet)

        vm.setLanguage("ja")
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.engineChoices, [.whisper], "Turbo is hidden for Japanese")
        XCTAssertEqual(vm.engineNote, "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support Japanese.")
        XCTAssertEqual(configStore.config.engine, "parakeet", "The choice is kept, not rewritten")
        XCTAssertEqual(engineModel.engine, .whisper)

        vm.setLanguage("de")
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertNil(vm.engineNote)
        XCTAssertEqual(engineModel.engine, .parakeet)
    }

    func testAMissingModelShowsItsEnginesHint() {
        configStore.update { $0.engine = "parakeet"; $0.engineModels = ["parakeet": .named("big")] }
        let vm = makeVM()
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Open Settings › Model to download it.")
    }

    /// The heading over models that aren't installed says how to get them,
    /// with the engine's own command: the model's when one is missing, a
    /// `<name>` placeholder when several are.
    func testTheNotDownloadedHeadingUsesTheEnginesDownloadCommand() {
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded — run: make model MODEL=<name>")

        configStore.update { $0.engine = "parakeet" }
        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [fakePath("fast")], hintsCommand: true)])
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded — run: make fake-model FAKE=big")

        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [], hintsCommand: true)])
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded — run: make fake-model FAKE=<name>")

        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [])])
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded — Open Settings › Model to download it.")
    }
}
