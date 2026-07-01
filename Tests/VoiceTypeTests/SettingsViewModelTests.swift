import XCTest
import ServiceManagement
@testable import VoiceType

/// Tests for SettingsViewModel — no UI, no hardware.
/// Uses ConfigStore on a temp file + injected fake login item service.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    // MARK: - Fake login item service

    private final class FakeLoginItemService: LoginItemService {
        var rawStatus: SMAppService.Status
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(status: SMAppService.Status = .notRegistered) {
            rawStatus = status
        }

        func register() throws {
            registerCallCount += 1
            if let err = registerError { throw err }
            rawStatus = .enabled
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let err = unregisterError { throw err }
            rawStatus = .notRegistered
        }
    }

    private struct FakeError: Error {}

    // MARK: - Test state

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var fakeLogin: FakeLoginItemService!
    private var menuRefreshCount = 0

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-vm-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        fakeLogin = FakeLoginItemService()
        menuRefreshCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - Helper

    private func makeVM(
        mics: [AudioInputDevice] = [],
        presentFiles: Set<String> = []
    ) -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { mics },
            presentModelFilenames: { presentFiles },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshCount += 1 },
            pauseHotkeys: {},
            reloadHotkeys: {}
        )
    }

    // MARK: - setSoundCues

    func testSetSoundCuesTruePersists() {
        let vm = makeVM()
        vm.setSoundCues(true)
        XCTAssertTrue(configStore.config.soundCues)
        XCTAssertTrue(vm.soundCues)
    }

    func testSetSoundCuesFalsePersists() {
        configStore.update { $0.soundCues = true }
        let vm = makeVM()
        vm.setSoundCues(false)
        XCTAssertFalse(configStore.config.soundCues)
        XCTAssertFalse(vm.soundCues)
    }

    // MARK: - selectMic

    func testSelectMicSetsUID() {
        let vm = makeVM()
        vm.selectMic("X")
        XCTAssertEqual(configStore.config.microphoneUID, "X")
        XCTAssertEqual(vm.selectedMicUID, "X")
    }

    func testSelectMicFiresMenuRefresh() {
        let vm = makeVM()
        vm.selectMic("X")
        XCTAssertGreaterThan(menuRefreshCount, 0, "selectMic must call onNeedsMenuRefresh")
    }

    func testSelectMicNilClearsUID() {
        configStore.update { $0.microphoneUID = "X" }
        let vm = makeVM()
        vm.selectMic(nil)
        XCTAssertNil(configStore.config.microphoneUID)
        XCTAssertNil(vm.selectedMicUID)
    }

    // MARK: - selectModel

    func testSelectModelSetsPathSuffix() {
        let vm = makeVM()
        vm.selectModel("small.en")
        XCTAssertTrue(configStore.config.modelPath.hasSuffix("ggml-small.en.bin"),
                      "modelPath must end with the expected filename")
    }

    func testSelectModelUpdatesSelectedSize() {
        let vm = makeVM()
        vm.selectModel("small.en")
        XCTAssertEqual(vm.selectedModelSize, "small.en")
    }

    func testSelectModelSetsNeedsRestart() {
        let vm = makeVM()
        vm.selectModel("small.en")
        XCTAssertTrue(vm.modelChangeNeedsRestart)
    }

    func testSelectModelFiresMenuRefresh() {
        let vm = makeVM()
        vm.selectModel("tiny.en")
        XCTAssertGreaterThan(menuRefreshCount, 0, "selectModel must call onNeedsMenuRefresh")
    }

    // MARK: - setLaunchAtLogin (success)

    func testSetLaunchAtLoginTrueCallsRegister() {
        let vm = makeVM()
        vm.setLaunchAtLogin(true)
        XCTAssertEqual(fakeLogin.registerCallCount, 1)
        XCTAssertTrue(vm.launchAtLogin)
        XCTAssertNil(vm.loginError)
    }

    // MARK: - setLaunchAtLogin (error → revert)

    func testSetLaunchAtLoginTrueFailureRevertsAndSetsError() {
        fakeLogin.registerError = FakeError()
        let vm = makeVM()
        vm.setLaunchAtLogin(true)
        XCTAssertFalse(vm.launchAtLogin, "launchAtLogin must revert to false on error")
        XCTAssertNotNil(vm.loginError, "loginError must be set after a failed register()")
    }
}
