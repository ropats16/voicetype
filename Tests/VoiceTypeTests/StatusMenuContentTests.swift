import XCTest
@testable import VoiceType

/// `StatusMenuContent`: what the menu-bar menu shows for a status, the
/// permission inputs and the config. Pure; no AppKit.
final class StatusMenuContentTests: XCTestCase {
    private func content(_ status: AppStatus,
                         accessibility: AccessibilityPermission = .granted,
                         microphone: MicrophonePermission = .authorized,
                         engine: TranscriptionStatus = .ready,
                         configIssues: [ConfigIssue] = []) -> StatusMenuContent {
        let inputs = ReadinessInputs(
            accessibility: accessibility, microphone: microphone,
            engine: EngineReadiness(status: engine, modelPath: "/m.bin", downloadCommand: "make model"),
            hotkeyTap: .installed)
        return StatusMenuContent(status: status, inputs: inputs, hold: "⌃⇧", toggle: "⌃⌥Space",
                                 configIssues: configIssues)
    }

    func testReady() {
        let menu = content(.ready)
        XCTAssertEqual(menu.header, "VoiceType — Ready")
        XCTAssertEqual(menu.symbol, "mic")
        XCTAssertNil(menu.reason)
        XCTAssertEqual(menu.microphone, .init(title: "Microphone: Granted", action: nil))
        XCTAssertEqual(menu.accessibility, .init(title: "Accessibility: Granted", action: nil))
        XCTAssertEqual(menu.hold, "Hold to talk: ⌃⇧")
        XCTAssertEqual(menu.toggle, "Toggle to talk: ⌃⌥Space")
        XCTAssertNil(menu.configIssues)
        XCTAssertNil(menu.modelHint)
    }

    func testMicDeniedShowsReasonAndFix() {
        let menu = content(.notReady(.microphoneDenied), microphone: .denied)
        XCTAssertEqual(menu.header, "VoiceType — Needs Microphone")
        XCTAssertEqual(menu.symbol, "mic.slash")
        XCTAssertEqual(menu.reason, .init(title: ReadinessIssue.microphoneDenied.detail,
                                          action: .openMicrophoneSettings))
        XCTAssertEqual(menu.microphone, .init(title: "Microphone: Not granted", action: .openMicrophoneSettings))
    }

    func testUndeterminedMicRowAsksForAccess() {
        let menu = content(.notReady(.microphoneNotDetermined), microphone: .notDetermined)
        XCTAssertEqual(menu.microphone.action, .requestMicrophone)
    }

    func testAccessibilityRowClickableWhenDenied() {
        let menu = content(.notReady(.accessibilityNeeded), accessibility: .denied)
        XCTAssertEqual(menu.accessibility, .init(title: "Accessibility: Not granted",
                                                 action: .openAccessibilitySettings))
    }

    func testModelMissingAndFailedAreDistinct() {
        let missing = content(.notReady(.modelMissing(path: "/m.bin", downloadCommand: "make model")))
        let failed = content(.notReady(.modelFailed(reason: "checksum mismatch", downloadCommand: "make model")))

        XCTAssertEqual(missing.header, "VoiceType — Model missing")
        XCTAssertEqual(missing.reason?.title, "Model missing — run `make model`")
        XCTAssertEqual(failed.header, "VoiceType — Model failed to load")
        XCTAssertEqual(failed.reason?.title,
                       "Model failed to load — see log, or try `make model` to re-download it")
        XCTAssertEqual(missing.reason?.action, .openModelsFolder)
        XCTAssertEqual(failed.reason?.action, .openModelsFolder)
    }

    func testModelProblemBehindAPermissionStillShowsItsHint() {
        let menu = content(.notReady(.accessibilityNeeded), accessibility: .denied, engine: .missing)
        XCTAssertEqual(menu.reason?.action, .openAccessibilitySettings)
        XCTAssertEqual(menu.modelHint, .init(title: "Model missing — run `make model`", action: .openModelsFolder))

        let failed = content(.notReady(.microphoneDenied), microphone: .denied, engine: .failed(reason: "x"))
        XCTAssertEqual(failed.modelHint?.title, "Model failed to load — see log, or try `make model` to re-download it")
    }

    func testModelHintIsNotRepeatedWhenItIsTheReason() {
        let issue = ReadinessIssue.modelMissing(path: "/m.bin", downloadCommand: "make model")
        let menu = content(.notReady(issue), engine: .missing)
        XCTAssertEqual(menu.reason?.title, issue.detail)
        XCTAssertNil(menu.modelHint)
    }

    func testTransientStatusHasNoReasonLine() {
        let menu = content(.starting(.modelLoading))
        XCTAssertEqual(menu.header, "VoiceType — Loading model…")
        XCTAssertEqual(menu.symbol, "mic")
        XCTAssertNil(menu.reason)
    }

    func testConfigLineOnlyWithErrorsCountsAllIssues() {
        let warning = ConfigIssue(severity: .warning, message: "w")
        let error = ConfigIssue(severity: .error, message: "e")
        XCTAssertNil(content(.ready, configIssues: [warning]).configIssues)
        XCTAssertEqual(content(.ready, configIssues: [error, warning]).configIssues,
                       "⚠️ Config: 2 config issue(s) — see log")
    }
}
