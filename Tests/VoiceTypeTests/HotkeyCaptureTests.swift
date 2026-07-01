import XCTest
import AppKit
@testable import VoiceType

/// Unit tests for the pure `HotkeyCapture` conversion helpers.
/// No hardware, no event tap — synthetic inputs → `KeyBinding` only.
final class HotkeyCaptureTests: XCTestCase {

    // MARK: - modifierNames

    func testModifierNamesControlShift() {
        let names = HotkeyCapture.modifierNames(from: [.control, .shift])
        XCTAssertEqual(names, ["control", "shift"])
    }

    func testModifierNamesCanonicalOrder() {
        // Input order must not affect output; canonical order: control, option, shift, command, function
        let names = HotkeyCapture.modifierNames(from: [.command, .shift, .option, .control])
        XCTAssertEqual(names, ["control", "option", "shift", "command"])
    }

    func testModifierNamesExcludesOthers() {
        // .capsLock is not in the recognized set
        let names = HotkeyCapture.modifierNames(from: [.control, .capsLock])
        XCTAssertEqual(names, ["control"])
    }

    func testModifierNamesEmpty() {
        XCTAssertEqual(HotkeyCapture.modifierNames(from: []), [])
    }

    func testModifierNamesFunction() {
        let names = HotkeyCapture.modifierNames(from: [.function, .shift])
        XCTAssertEqual(names, ["shift", "function"])
    }

    // MARK: - regularKeyBinding

    func testRegularKeyBindingControlOptionSpace() {
        let result = HotkeyCapture.regularKeyBinding(keyCode: 49, flags: [.control, .option])
        XCTAssertEqual(result, KeyBinding(keyCode: 49, modifiers: ["control", "option"]))
    }

    func testRegularKeyBindingNoModifiers() {
        let result = HotkeyCapture.regularKeyBinding(keyCode: 36, flags: [])
        XCTAssertEqual(result, KeyBinding(keyCode: 36, modifiers: []))
    }

    func testRegularKeyBindingShiftKey() {
        let result = HotkeyCapture.regularKeyBinding(keyCode: 5, flags: [.shift])
        XCTAssertEqual(result, KeyBinding(keyCode: 5, modifiers: ["shift"]))
    }

    // MARK: - modifierOnlyBinding

    func testModifierOnlyBindingTwoModifiers() {
        // 2 modifiers → pure-modifier combo, form 1
        let result = HotkeyCapture.modifierOnlyBinding(
            names: ["control", "shift"], lastModifierKeyCode: 60)
        XCTAssertEqual(result, KeyBinding(keyCode: -1, modifiers: ["control", "shift"]))
    }

    func testModifierOnlyBindingSingleModifierRightOption() {
        // 1 modifier + valid modifier key code → single-modifier form, form 2
        let result = HotkeyCapture.modifierOnlyBinding(
            names: ["option"], lastModifierKeyCode: 61)
        XCTAssertEqual(result, KeyBinding(keyCode: 61, modifiers: []))
    }

    func testModifierOnlyBindingEmptyNamesReturnsNil() {
        XCTAssertNil(HotkeyCapture.modifierOnlyBinding(names: [], lastModifierKeyCode: nil))
    }

    func testModifierOnlyBindingSingleModifierNilKeyCodeReturnsNil() {
        // Can't form a single-modifier binding without a recorded key code
        XCTAssertNil(HotkeyCapture.modifierOnlyBinding(names: ["control"], lastModifierKeyCode: nil))
    }

    func testModifierOnlyBindingSingleModifierNonModifierKeyCodeReturnsNil() {
        // Key code 49 (Space) is not a modifier key → nil
        XCTAssertNil(HotkeyCapture.modifierOnlyBinding(names: ["control"], lastModifierKeyCode: 49))
    }

    func testModifierOnlyBindingThreeModifiers() {
        // 3 modifiers → still form 1 (pure-modifier combo)
        let result = HotkeyCapture.modifierOnlyBinding(
            names: ["control", "option", "shift"], lastModifierKeyCode: 56)
        XCTAssertEqual(result, KeyBinding(keyCode: -1, modifiers: ["control", "option", "shift"]))
    }

    func testModifierOnlyBindingSingleModifierLeftControl() {
        let result = HotkeyCapture.modifierOnlyBinding(
            names: ["control"], lastModifierKeyCode: 59)
        XCTAssertEqual(result, KeyBinding(keyCode: 59, modifiers: []))
    }
}
