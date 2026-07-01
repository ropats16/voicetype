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
    private var reloadCount = 0
    private var pauseCount = 0

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-vm-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        fakeLogin = FakeLoginItemService()
        menuRefreshCount = 0
        reloadCount = 0
        pauseCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - Helpers

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

    /// VM variant that wires spy closures for `pauseHotkeys` and `reloadHotkeys`.
    private func makeVMWithSpies() -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { [] },
            presentModelFilenames: { Set() },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshCount += 1 },
            pauseHotkeys: { [weak self] in self?.pauseCount += 1 },
            reloadHotkeys: { [weak self] in self?.reloadCount += 1 }
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

    // MARK: - beginHotkeyCapture

    func testBeginHotkeyCaptureFiresPauseAndSetsCapturing() {
        let vm = makeVMWithSpies()
        vm.beginHotkeyCapture()
        XCTAssertEqual(pauseCount, 1, "beginHotkeyCapture must call pauseHotkeys")
        XCTAssertTrue(vm.isCapturing, "isCapturing must be true after beginHotkeyCapture")
    }

    // MARK: - commitHotkey

    func testCommitHotkeyPersistsBindingAndFiresCallbacks() {
        let vm = makeVMWithSpies()
        let newBinding = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
        vm.commitHotkey(newBinding, for: .hold)
        XCTAssertEqual(configStore.config.hold, newBinding, "config.hold must be persisted")
        XCTAssertEqual(vm.holdBinding, newBinding, "holdBinding must be updated")
        XCTAssertGreaterThan(reloadCount, 0, "reloadHotkeys must be called")
        XCTAssertGreaterThan(menuRefreshCount, 0, "onNeedsMenuRefresh must be called")
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after commit")
    }

    func testCommitHotkeyTogglePersistsBinding() {
        let vm = makeVMWithSpies()
        let newBinding = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        vm.commitHotkey(newBinding, for: .toggle)
        XCTAssertEqual(configStore.config.toggle, newBinding)
        XCTAssertEqual(vm.toggleBinding, newBinding)
    }

    func testCommitHotkeyNilCancelsAndResumesWithoutMenuRefresh() {
        let vm = makeVMWithSpies()
        vm.beginHotkeyCapture()
        let beforeMenuCount = menuRefreshCount
        vm.commitHotkey(nil, for: .hold)
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after cancel")
        XCTAssertGreaterThan(reloadCount, 0, "reloadHotkeys must be called to resume tap")
        XCTAssertEqual(menuRefreshCount, beforeMenuCount, "onNeedsMenuRefresh must NOT be called on cancel")
    }

    func testCommitHotkeyConflictSetsWarning() {
        // Setting hold == current toggle → ConfigValidator detects conflict → hotkeyWarning != nil
        let vm = makeVMWithSpies()
        let conflicting = configStore.config.toggle   // same as toggle default
        vm.commitHotkey(conflicting, for: .hold)
        XCTAssertNotNil(vm.hotkeyWarning, "hotkeyWarning must be set when hold == toggle")
    }

    func testCommitHotkeyNoConflictClearsWarning() {
        let vm = makeVMWithSpies()
        // First create a conflict, then resolve it
        let conflicting = configStore.config.toggle
        vm.commitHotkey(conflicting, for: .hold)
        XCTAssertNotNil(vm.hotkeyWarning)
        // Now restore defaults
        vm.resetHotkey(.hold)
        XCTAssertNil(vm.hotkeyWarning, "hotkeyWarning must be nil when bindings are valid")
    }

    // MARK: - resetHotkey

    func testResetHotkeyHoldRestoresControlShift() {
        // Change hold to something non-default first
        configStore.update { $0.hold = KeyBinding(keyCode: 36, modifiers: []) }
        let vm = makeVMWithSpies()
        vm.resetHotkey(.hold)
        XCTAssertEqual(configStore.config.hold, .controlShift)
        XCTAssertEqual(vm.holdBinding, .controlShift)
    }

    func testResetHotkeyToggleRestoresControlOptionSpace() {
        configStore.update { $0.toggle = KeyBinding(keyCode: 36, modifiers: []) }
        let vm = makeVMWithSpies()
        vm.resetHotkey(.toggle)
        XCTAssertEqual(configStore.config.toggle, .controlOptionSpace)
        XCTAssertEqual(vm.toggleBinding, .controlOptionSpace)
    }

    func testResetHotkeyFiresReloadAndMenuRefresh() {
        let vm = makeVMWithSpies()
        vm.resetHotkey(.hold)
        XCTAssertGreaterThan(reloadCount, 0)
        XCTAssertGreaterThan(menuRefreshCount, 0)
    }

    // MARK: - cancelCapture (C1 teardown path)

    func testCancelCaptureIsNoOpWhenIdle() {
        // When no capture is active, cancelCapture must not crash and must NOT
        // call reloadHotkeys (recorder.captureTarget is nil → finishCapture returns early).
        let vm = makeVMWithSpies()
        vm.cancelCapture()
        XCTAssertFalse(vm.isCapturing)
        XCTAssertEqual(reloadCount, 0, "cancelCapture must be a no-op when not capturing")
    }

    func testCancelCaptureTeardownCapturingState() {
        // After startCapture sets recorder.captureTarget, cancelCapture must
        // clear it, set isCapturing=false, and call reloadHotkeys (resume tap).
        let vm = makeVMWithSpies()
        vm.recorder.startCapture(for: .hold, vm: vm)
        XCTAssertTrue(vm.isCapturing, "isCapturing must be true after startCapture")
        XCTAssertNotNil(vm.recorder.captureTarget, "captureTarget must be set after startCapture")
        let reloadBefore = reloadCount
        vm.cancelCapture()
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after cancelCapture")
        XCTAssertNil(vm.recorder.captureTarget, "captureTarget must be nil after cancelCapture")
        XCTAssertGreaterThan(reloadCount, reloadBefore, "cancelCapture must call reloadHotkeys to resume tap")
    }

    // MARK: - holdDescription / toggleDescription

    func testHoldDescriptionMatchesDefaultControlShift() {
        let vm = makeVM()
        // .controlShift → keyCode -1, ["control","shift"] → "⌃ ⇧" or similar via HotkeyDescription
        XCTAssertFalse(vm.holdDescription.isEmpty)
    }

    func testToggleDescriptionMatchesDefaultControlOptionSpace() {
        let vm = makeVM()
        XCTAssertFalse(vm.toggleDescription.isEmpty)
    }
}
