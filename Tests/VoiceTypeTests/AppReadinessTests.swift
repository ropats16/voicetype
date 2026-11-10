import XCTest
@testable import VoiceType

/// `AppReadiness` (pure inputs → status) and `ReadinessMonitor` (polling,
/// change-only emission, tap retry/re-arm), with a fake permission probe,
/// engine status, hotkey tap and a manual clock: no TCC, no model, no tap.
final class AppReadinessTests: XCTestCase {
    private final class FakeProbe: PermissionProbe {
        var accessibility: AccessibilityPermission = .granted
        var microphone: MicrophonePermission = .authorized
    }

    /// Stands in for `HotkeyManager`: each install attempt reports `result`.
    private final class FakeTap {
        var result: HotkeyTapHealth = .installed
        private(set) var installs = 0
        func install(into monitor: ReadinessMonitor) {
            installs += 1
            monitor.hotkeyTapChanged(result)
        }
    }

    private static let modelPath = "/models/ggml-base.en.bin"
    private static let download = "make model MODEL=base.en"

    private func engine(_ status: TranscriptionStatus, download: String? = AppReadinessTests.download) -> EngineReadiness {
        EngineReadiness(status: status, modelPath: Self.modelPath, downloadCommand: download)
    }

    private func inputs(accessibility: AccessibilityPermission = .granted,
                        microphone: MicrophonePermission = .authorized,
                        engine status: TranscriptionStatus = .ready,
                        tap: HotkeyTapHealth = .installed) -> ReadinessInputs {
        ReadinessInputs(accessibility: accessibility, microphone: microphone,
                        engine: engine(status), hotkeyTap: tap)
    }

    // MARK: - Monitor harness

    private var probe: FakeProbe!
    private var clock: ManualClock!
    private var tap: FakeTap!
    private var monitor: ReadinessMonitor!
    private var changes: [AppStatus] = []
    private var inputChanges: [ReadinessInputs] = []
    private var becameReady: [Bool] = []   // isFirst per transition

    override func setUp() {
        super.setUp()
        probe = FakeProbe()
        clock = ManualClock()
        tap = FakeTap()
        changes = []
        inputChanges = []
        becameReady = []
    }

    private func makeMonitor(engine status: TranscriptionStatus = .ready) {
        monitor = ReadinessMonitor(probe: probe, clock: clock, engine: engine(status),
                                   pollInterval: 2, readyPollInterval: 10)
        monitor.onChange = { [unowned self] in changes.append($0) }
        monitor.onInputsChange = { [unowned self] in inputChanges.append($0) }
        monitor.onBecameReady = { [unowned self] isFirst in becameReady.append(isFirst) }
        monitor.onTapNeeded = { [unowned self] in tap.install(into: monitor) }
    }

    private func startMonitor(engine status: TranscriptionStatus = .ready) {
        makeMonitor(engine: status)
        monitor.start()
    }

    /// Seconds until the next poll.
    private var nextPollIn: TimeInterval? {
        clock.live.map(\.due).min().map { $0 - clock.now }
    }

    // MARK: - Status: reasons

    func testEverythingGrantedLoadedAndTappedIsReady() {
        XCTAssertEqual(AppReadiness.status(for: inputs()), .ready)
        XCTAssertEqual(AppStatus.ready.title, "Ready")
    }

    func testMicDeniedIsNotReadyWithReasonAndSettingsAction() {
        let status = AppReadiness.status(for: inputs(microphone: .denied))
        XCTAssertEqual(status, .notReady(.microphoneDenied))
        XCTAssertEqual(status.title, "Needs Microphone")
        XCTAssertEqual(status.issue?.action, .openMicrophoneSettings)
        XCTAssertFalse(status.issue?.detail.isEmpty ?? true)
        XCTAssertFalse(status.allowsDictation, "A denied mic must not record silence")
    }

    func testMicRestrictedAndUndeterminedAreDistinctReasons() {
        XCTAssertEqual(AppReadiness.status(for: inputs(microphone: .restricted)), .notReady(.microphoneRestricted))
        let undetermined = AppReadiness.status(for: inputs(microphone: .notDetermined))
        XCTAssertEqual(undetermined, .notReady(.microphoneNotDetermined))
        XCTAssertEqual(undetermined.issue?.action, .requestMicrophone)
        XCTAssertFalse(undetermined.allowsDictation)
    }

    func testAccessibilityDeniedNeedsAccessibility() {
        let status = AppReadiness.status(for: inputs(accessibility: .denied, tap: .notInstalled))
        XCTAssertEqual(status, .notReady(.accessibilityNeeded))
        XCTAssertEqual(status.title, "Needs Accessibility")
        XCTAssertEqual(status.issue?.action, .openAccessibilitySettings)
    }

    func testModelMissingAndFailedAreDistinct() {
        let missing = AppReadiness.status(for: inputs(engine: .missing))
        let failed = AppReadiness.status(for: inputs(engine: .failed(reason: "bad file")))

        XCTAssertEqual(missing, .notReady(.modelMissing(path: Self.modelPath, downloadCommand: Self.download)))
        XCTAssertEqual(failed, .notReady(.modelFailed(reason: "bad file", downloadCommand: Self.download)))
        XCTAssertNotEqual(missing, failed)
        XCTAssertEqual(missing.title, "Model missing")
        XCTAssertEqual(failed.title, "Model failed to load")
        XCTAssertNotEqual(missing.issue?.detail, failed.issue?.detail)
        XCTAssertEqual(missing.issue?.action, .openModelsFolder)
        XCTAssertFalse(missing.allowsDictation)
        XCTAssertFalse(failed.allowsDictation)
    }

    func testModelHintsKeepTheMenuWording() {
        XCTAssertEqual(ReadinessIssue.modelMissing(path: Self.modelPath, downloadCommand: Self.download).detail,
                       "Model missing — run `\(Self.download)`")
        XCTAssertEqual(ReadinessIssue.modelMissing(path: Self.modelPath, downloadCommand: nil).detail,
                       "Model file missing — see Settings")
        XCTAssertEqual(ReadinessIssue.modelFailed(reason: "x", downloadCommand: nil).detail,
                       "Model failed to load — see log")
        XCTAssertEqual(ReadinessIssue.modelFailed(reason: "x", downloadCommand: Self.download).detail,
                       "Model failed to load — see log, or try `\(Self.download)` to re-download it")
    }

    func testLoadingAndVerifyingAreTransientAndStillAllowDictation() {
        let loading = AppReadiness.status(for: inputs(engine: .loading))
        XCTAssertEqual(loading, .starting(.modelLoading))
        XCTAssertEqual(loading.title, "Loading model…")
        XCTAssertTrue(loading.allowsDictation, "Jobs queue behind a loading model")
        XCTAssertEqual(AppReadiness.status(for: inputs(engine: .notLoaded)), .starting(.modelLoading))

        let verifying = AppReadiness.status(for: inputs(engine: .verifying))
        XCTAssertEqual(verifying, .starting(.modelVerifying))
        XCTAssertEqual(verifying.title, "Verifying model…")
        XCTAssertTrue(verifying.allowsDictation)
    }

    func testTapNotYetInstalledIsTransientTapFailedIsActionable() {
        let pending = AppReadiness.status(for: inputs(tap: .notInstalled))
        XCTAssertEqual(pending, .starting(.hotkeysStarting))
        XCTAssertFalse(pending.allowsDictation, "No hotkeys yet")
        let failed = AppReadiness.status(for: inputs(tap: .failed))
        XCTAssertEqual(failed, .notReady(.hotkeyTapFailed))
        XCTAssertEqual(failed.issue?.action, .openAccessibilitySettings)
    }

    // MARK: - Status: priority

    func testIssuesAreListedInPriorityOrder() {
        let all = AppReadiness.issues(for: inputs(microphone: .denied, engine: .failed(reason: "r"), tap: .failed))
        XCTAssertEqual(all, [.microphoneDenied, .modelFailed(reason: "r", downloadCommand: Self.download), .hotkeyTapFailed])

        let transient = AppReadiness.issues(for: inputs(engine: .verifying, tap: .notInstalled))
        XCTAssertEqual(transient, [.hotkeysStarting, .modelVerifying])
    }

    func testAccessibilityOutranksEverything() {
        let status = AppReadiness.status(for: inputs(accessibility: .denied, microphone: .denied,
                                                     engine: .missing, tap: .failed))
        XCTAssertEqual(status, .notReady(.accessibilityNeeded))
    }

    func testTapIssuesAreHiddenWhileAccessibilityIsDenied() {
        let issues = AppReadiness.issues(for: inputs(accessibility: .denied, tap: .failed))
        XCTAssertEqual(issues, [.accessibilityNeeded], "No tap without Accessibility; one fix, one reason")
    }

    func testActionableOutranksTransient() {
        XCTAssertEqual(AppReadiness.status(for: inputs(microphone: .denied, engine: .loading)),
                       .notReady(.microphoneDenied))
        XCTAssertEqual(AppReadiness.status(for: inputs(engine: .loading, tap: .failed)),
                       .notReady(.hotkeyTapFailed))
    }

    func testPermissionsOutrankModelProblems() {
        XCTAssertEqual(AppReadiness.status(for: inputs(microphone: .notDetermined, engine: .missing)),
                       .notReady(.microphoneNotDetermined))
        XCTAssertEqual(AppReadiness.status(for: inputs(engine: .missing, tap: .failed)),
                       .notReady(.modelMissing(path: Self.modelPath, downloadCommand: Self.download)))
    }

    // MARK: - Monitor: emission

    func testStartInstallsTapAndEmitsReadyOnce() {
        startMonitor()
        XCTAssertEqual(tap.installs, 1)
        XCTAssertEqual(changes, [.ready])
        XCTAssertEqual(becameReady, [true])
        XCTAssertEqual(monitor.status, .ready)
    }

    func testIdenticalTicksEmitNothing() {
        startMonitor()
        for _ in 0..<10 { clock.advance(by: 10) }
        XCTAssertEqual(changes, [.ready], "Staying ready emits nothing — the menu isn't rebuilt per tick")
        XCTAssertEqual(becameReady, [true], "Ready reached (and logged) once")
        XCTAssertEqual(tap.installs, 1, "A healthy tap isn't reinstalled")

        probe.accessibility = .denied
        clock.advance(by: 10)
        for _ in 0..<10 { clock.advance(by: 2) }
        XCTAssertEqual(changes, [.ready, .notReady(.accessibilityNeeded)])
    }

    func testMicDeniedNeverBecomesReady() {
        probe.microphone = .denied
        startMonitor()
        for _ in 0..<5 { clock.advance(by: 2) }
        XCTAssertEqual(changes, [.notReady(.microphoneDenied)])
        XCTAssertEqual(becameReady, [])
    }

    func testGrantingAccessibilityWhileRunningReachesReadyOnce() {
        probe.accessibility = .denied
        startMonitor()
        XCTAssertEqual(changes, [.notReady(.accessibilityNeeded)])
        XCTAssertEqual(tap.installs, 0, "No tap attempt without Accessibility")

        clock.advance(by: 2)
        clock.advance(by: 2)
        XCTAssertEqual(changes.count, 1)

        probe.accessibility = .granted
        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 1)
        XCTAssertEqual(changes, [.notReady(.accessibilityNeeded), .ready])
        XCTAssertEqual(becameReady, [true])
    }

    func testInputsChangeIsReportedEvenWhenStatusIsUnchanged() {
        probe.accessibility = .denied
        probe.microphone = .notDetermined
        startMonitor()
        XCTAssertEqual(inputChanges.count, 1)

        probe.microphone = .authorized   // the mic prompt was answered; AX still blocks
        clock.advance(by: 2)
        XCTAssertEqual(changes, [.notReady(.accessibilityNeeded)])
        XCTAssertEqual(inputChanges.last?.microphone, .authorized)
        XCTAssertEqual(inputChanges.count, 2)

        clock.advance(by: 2)
        XCTAssertEqual(inputChanges.count, 2, "Identical inputs aren't re-reported")
    }

    // MARK: - Monitor: polling policy

    func testPollsFastWhileNotReadyAndSlowWhenReady() {
        probe.accessibility = .denied
        startMonitor()
        XCTAssertEqual(nextPollIn, 2)

        probe.accessibility = .granted
        clock.advance(by: 2)
        XCTAssertEqual(monitor.status, .ready)
        XCTAssertEqual(nextPollIn, 10)
        XCTAssertEqual(clock.live.count, 1, "One poll pending at a time")
    }

    func testRevokedAccessibilityAfterReadyRearmsRetryAndRecovers() {
        startMonitor()
        XCTAssertEqual(becameReady, [true])

        probe.accessibility = .denied
        clock.advance(by: 10)
        XCTAssertEqual(monitor.status, .notReady(.accessibilityNeeded))
        XCTAssertEqual(monitor.inputs.hotkeyTap, .notInstalled, "A tap from before the revoke is presumed dead")
        XCTAssertEqual(nextPollIn, 2, "Fast polling re-armed")

        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 1, "No reinstall while Accessibility is off")

        probe.accessibility = .granted
        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 2, "Tap reinstalled after the re-grant")
        XCTAssertEqual(changes, [.ready, .notReady(.accessibilityNeeded), .ready])
        XCTAssertEqual(becameReady, [true, false], "One signal per transition into ready")

        for _ in 0..<5 { clock.advance(by: 10) }
        XCTAssertEqual(becameReady, [true, false])
        XCTAssertEqual(tap.installs, 2)
    }

    func testFailedTapIsRetriedEachPollUntilItInstalls() {
        tap.result = .failed
        startMonitor()
        XCTAssertEqual(changes, [.notReady(.hotkeyTapFailed)])
        XCTAssertEqual(nextPollIn, 2)

        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 2)
        XCTAssertEqual(changes.count, 1)

        tap.result = .installed
        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 3)
        XCTAssertEqual(changes, [.notReady(.hotkeyTapFailed), .ready])
        XCTAssertEqual(becameReady, [true])
    }

    func testTapFailureReportedLaterRearmsFastPolling() {
        startMonitor()
        XCTAssertEqual(nextPollIn, 10)

        monitor.hotkeyTapChanged(.failed)   // e.g. a Settings rebind couldn't install the new tap
        XCTAssertEqual(changes, [.ready, .notReady(.hotkeyTapFailed)])
        XCTAssertEqual(nextPollIn, 2)

        clock.advance(by: 2)
        XCTAssertEqual(tap.installs, 2)
        XCTAssertEqual(changes.last, .ready)
    }

    // MARK: - Monitor: engine pushes

    func testEngineStatusPushesEmitImmediatelyAndOnlyOnChange() {
        startMonitor(engine: .loading)
        XCTAssertEqual(changes, [.starting(.modelLoading)])
        XCTAssertEqual(becameReady, [])

        monitor.engineChanged(engine(.ready))
        XCTAssertEqual(changes, [.starting(.modelLoading), .ready])
        XCTAssertEqual(becameReady, [true])

        monitor.engineChanged(engine(.failed(reason: "boom")))
        monitor.engineChanged(engine(.failed(reason: "boom")))
        XCTAssertEqual(changes.last, .notReady(.modelFailed(reason: "boom", downloadCommand: Self.download)))
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(nextPollIn, 2)

        monitor.engineChanged(engine(.ready))
        XCTAssertEqual(becameReady, [true, false])
    }

    func testModelMissingAndFailedAreEmittedDistinctly() {
        startMonitor(engine: .missing)
        monitor.engineChanged(engine(.failed(reason: "corrupt")))
        XCTAssertEqual(changes, [
            .notReady(.modelMissing(path: Self.modelPath, downloadCommand: Self.download)),
            .notReady(.modelFailed(reason: "corrupt", downloadCommand: Self.download)),
        ])
    }

    // MARK: - Monitor: lifecycle

    func testRecheckPollsNow() {
        probe.accessibility = .denied
        startMonitor()
        probe.accessibility = .granted
        monitor.recheck()
        XCTAssertEqual(monitor.status, .ready)
        XCTAssertEqual(clock.live.count, 1, "The pending poll is replaced, not doubled")
        XCTAssertEqual(nextPollIn, 10)
    }

    func testNothingIsEmittedBeforeStart() {
        makeMonitor()
        monitor.engineChanged(engine(.loading))
        XCTAssertEqual(changes, [])
        XCTAssertEqual(clock.live.count, 0)
    }

    func testStopCancelsPolling() {
        probe.accessibility = .denied
        startMonitor()
        monitor.stop()
        XCTAssertEqual(clock.live.count, 0)
        probe.accessibility = .granted
        clock.advance(by: 2)
        XCTAssertEqual(changes, [.notReady(.accessibilityNeeded)])
    }
}
