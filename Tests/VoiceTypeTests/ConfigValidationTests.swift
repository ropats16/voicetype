import XCTest
@testable import VoiceType

/// Tests for the pure binding/config validation layer (Phase 2, Task 1).
/// Validation is reporting-only: it must never mutate the config, just inspect
/// it and surface an ordered list of problems.
final class ConfigValidationTests: XCTestCase {

    private func errors(_ config: Config) -> [ConfigIssue] {
        ConfigValidator.validate(config).filter { $0.severity == .error }
    }

    private func warnings(_ config: Config) -> [ConfigIssue] {
        ConfigValidator.validate(config).filter { $0.severity == .warning }
    }

    // MARK: - Clean baseline

    func testDefaultConfigHasNoIssues() {
        XCTAssertTrue(ConfigValidator.validate(.defaults).isEmpty,
                      "The shipped defaults must validate cleanly")
    }

    func testValidationIsDeterministic() {
        var config = Config.defaults
        config.toggle = config.hold            // an intentionally invalid config
        config.maxRecordingSeconds = -1
        let first = ConfigValidator.validate(config)
        let second = ConfigValidator.validate(config)
        XCTAssertEqual(first, second,
                       "Validating the same config twice must yield identical issues")
    }

    // MARK: - Error — hold == toggle

    func testHoldEqualsToggleIsError() {
        var config = Config.defaults
        config.toggle = config.hold
        XCTAssertEqual(errors(config).count, 1)
    }

    func testHoldEqualsToggleWithReorderedModifiersIsError() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        config.toggle = KeyBinding(keyCode: -1, modifiers: ["shift", "control"])
        XCTAssertEqual(errors(config).count, 1,
                       "Modifier order must not matter when comparing bindings")
    }

    // MARK: - Error — empty/unmatchable binding

    func testEmptyHoldBindingIsError() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).count, 1)
    }

    func testEmptyToggleBindingIsError() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).count, 1)
    }

    func testPureModifierComboIsNotUnmatchable() {
        // keyCode < 0 WITH modifiers is the valid pure-modifier combo form.
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        XCTAssertTrue(errors(config).isEmpty)
    }

    // MARK: - Warning — cancel key collision

    func testCancelKeyCollidesWithToggleIsWarning() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
        config.cancelKeyCode = 49           // same real key as the toggle
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testCancelKeyCollidesWithHoldIsWarning() {
        // keyCode 50 avoids the default toggle's key code (49 = ⌃⌥Space), so
        // only the hold collision is exercised here.
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: 50, modifiers: ["control"])
        config.cancelKeyCode = 50
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testCancelKeyDoesNotCollideWithModifierComboKeyCode() {
        // hold/toggle keyCode of -1 must never be treated as a colliding key.
        var config = Config.defaults
        config.cancelKeyCode = -1
        XCTAssertTrue(warnings(config).isEmpty)
    }

    // MARK: - Warning — unknown modifier name

    func testUnknownModifierNameIsWarning() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["controll"])
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testKnownModifiersAreMatchedCaseInsensitively() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["Control", "SHIFT"])
        XCTAssertTrue(warnings(config).isEmpty)
    }

    // MARK: - Warning — non-positive max duration

    func testZeroMaxRecordingSecondsIsWarning() {
        var config = Config.defaults
        config.maxRecordingSeconds = 0
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testNegativeMaxRecordingSecondsIsWarning() {
        var config = Config.defaults
        config.maxRecordingSeconds = -5
        XCTAssertEqual(warnings(config).count, 1)
    }
}
