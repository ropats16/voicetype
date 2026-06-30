import XCTest
import CoreGraphics
@testable import VoiceType

/// Tests for the pure hotkey layer (Phase 2, Task 2): binding *satisfaction*
/// and press/release *edge detection*. These drive the logic with synthetic
/// event tuples `(eventType, keyCode, flags, isAutorepeat)` — no real
/// `CGEventTap` is ever created.
final class HotkeyMatcherTests: XCTestCase {

    // MARK: - Synthetic event helpers

    /// Satisfaction reading for one event against a binding (`nil` = irrelevant).
    private func sat(_ binding: KeyBinding,
                     _ type: CGEventType,
                     keyCode: Int = -1,
                     flags: CGEventFlags = [],
                     autorepeat: Bool = false) -> Bool? {
        HotkeyMatcher.satisfaction(of: binding, eventType: type,
                                   keyCode: keyCode, flags: flags, isAutorepeat: autorepeat)
    }

    /// Folds a sequence of events through a fresh `EdgeDetector`, returning the
    /// ordered edges crossed.
    private func edges(_ binding: KeyBinding,
                       _ events: [(CGEventType, Int, CGEventFlags, Bool)]) -> [EdgeDetector.Edge] {
        var detector = EdgeDetector()
        var result: [EdgeDetector.Edge] = []
        for (type, keyCode, flags, autorepeat) in events {
            let reading = sat(binding, type, keyCode: keyCode, flags: flags, autorepeat: autorepeat)
            if let edge = detector.update(with: reading) { result.append(edge) }
        }
        return result
    }

    // The default toggle: ⌃⌥Space (a regular key + two modifiers).
    private let ctrlOptSpace = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
    private let ctrlOptFlags: CGEventFlags = [.maskControl, .maskAlternate]

    // MARK: - Satisfaction: regular key + modifiers (the ⌃⌥Space fix)

    func testRegularKeySatisfiedWhenBothModifiersPresent() {
        XCTAssertEqual(sat(ctrlOptSpace, .keyDown, keyCode: 49, flags: ctrlOptFlags), true,
                       "⌃⌥Space must be satisfied on keyDown when both control and option are held")
    }

    func testRegularKeyNotSatisfiedWhenModifierMissing() {
        // Only control held — option missing. The old buggy path matched on
        // keyCode alone and would have (wrongly) fired here.
        XCTAssertEqual(sat(ctrlOptSpace, .keyDown, keyCode: 49, flags: [.maskControl]), false,
                       "⌃⌥Space must NOT be satisfied when a required modifier is absent")
    }

    func testRegularKeyNotSatisfiedOnKeyUp() {
        XCTAssertEqual(sat(ctrlOptSpace, .keyUp, keyCode: 49, flags: ctrlOptFlags), false,
                       "A keyUp for the bound key is a release, never satisfied")
    }

    func testRegularKeyIrrelevantForOtherKeyCode() {
        XCTAssertNil(sat(ctrlOptSpace, .keyDown, keyCode: 48, flags: ctrlOptFlags),
                     "A different key code must not pertain to the binding")
    }

    func testRegularKeyIrrelevantOnFlagsChanged() {
        XCTAssertNil(sat(ctrlOptSpace, .flagsChanged, keyCode: 49, flags: ctrlOptFlags),
                     "Modifier-only events must not pertain to a regular-key binding")
    }

    func testRegularKeyAutorepeatIsIrrelevant() {
        XCTAssertNil(sat(ctrlOptSpace, .keyDown, keyCode: 49, flags: ctrlOptFlags, autorepeat: true),
                     "An autorepeat keyDown is a still-held key, not a fresh press")
    }

    // MARK: - Toggle fires exactly once per physical press

    func testTogglePressEdgeFiresOncePerPhysicalPress() {
        let sequence: [(CGEventType, Int, CGEventFlags, Bool)] = [
            (.keyDown, 49, ctrlOptFlags, false),   // press            → press edge
            (.keyDown, 49, ctrlOptFlags, true),    // autorepeat       → no edge
            (.keyDown, 49, ctrlOptFlags, true),    // autorepeat       → no edge
            (.keyUp,   49, ctrlOptFlags, false),   // release          → release edge
            (.keyDown, 49, ctrlOptFlags, false),   // press again      → press edge
        ]
        let pressEdges = edges(ctrlOptSpace, sequence).filter { $0 == .press }
        XCTAssertEqual(pressEdges.count, 2,
                       "Two physical presses (despite autorepeat) must yield exactly two press edges")
    }

    // MARK: - Hold edges: pure-modifier combo (default ⌃⇧)

    func testHoldComboPressThenReleaseEdges() {
        let controlShift = KeyBinding.controlShift   // keyCode -1, ["control","shift"]
        let sequence: [(CGEventType, Int, CGEventFlags, Bool)] = [
            (.flagsChanged, -1, [.maskControl, .maskShift], false), // both down → press
            (.flagsChanged, -1, [.maskControl],            false),  // shift up  → release
        ]
        XCTAssertEqual(edges(controlShift, sequence), [.press, .release])
    }

    func testHoldComboNotSatisfiedWithPartialModifiers() {
        let controlShift = KeyBinding.controlShift
        XCTAssertEqual(sat(controlShift, .flagsChanged, flags: [.maskControl]), false,
                       "A combo is unsatisfied until every required modifier is held")
        XCTAssertEqual(sat(controlShift, .flagsChanged, flags: [.maskControl, .maskShift]), true)
    }

    // MARK: - Hold edges: single modifier (Right ⌥)

    func testHoldSingleModifierPressThenReleaseEdges() {
        let rightOption = KeyBinding.rightOption     // keyCode 61, []
        let deviceBit = CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
        let sequence: [(CGEventType, Int, CGEventFlags, Bool)] = [
            (.flagsChanged, 61, deviceBit.union(.maskAlternate), false), // down → press
            (.flagsChanged, 61, [],                              false), // up   → release
        ]
        XCTAssertEqual(edges(rightOption, sequence), [.press, .release])
    }

    func testHoldSingleModifierIgnoresOtherModifierKeyCode() {
        let rightOption = KeyBinding.rightOption
        // A flagsChanged for Left Option (58) must not pertain to Right Option.
        XCTAssertNil(sat(rightOption, .flagsChanged, keyCode: 58, flags: .maskAlternate))
    }

    // MARK: - Cancel key detection (Phase 2, Task 3)

    // Esc is the default cancel key; it is a plain, non-modifier key.
    private let escKeyCode = 53

    func testCancelKeyDownTriggersCancel() {
        XCTAssertTrue(
            HotkeyMatcher.isCancelKeyDown(eventType: .keyDown, keyCode: escKeyCode,
                                          cancelKeyCode: escKeyCode, isAutorepeat: false),
            "A fresh keyDown for the cancel key code must trigger a cancel")
    }

    func testCancelKeyUpDoesNotTrigger() {
        XCTAssertFalse(
            HotkeyMatcher.isCancelKeyDown(eventType: .keyUp, keyCode: escKeyCode,
                                          cancelKeyCode: escKeyCode, isAutorepeat: false),
            "A keyUp for the cancel key code is a release, never a cancel trigger")
    }

    func testCancelKeyAutorepeatDoesNotTrigger() {
        XCTAssertFalse(
            HotkeyMatcher.isCancelKeyDown(eventType: .keyDown, keyCode: escKeyCode,
                                          cancelKeyCode: escKeyCode, isAutorepeat: true),
            "An autorepeat keyDown is a still-held key; it must not fire repeated cancels")
    }

    func testCancelOtherKeyCodeDoesNotTrigger() {
        XCTAssertFalse(
            HotkeyMatcher.isCancelKeyDown(eventType: .keyDown, keyCode: 49,
                                          cancelKeyCode: escKeyCode, isAutorepeat: false),
            "A keyDown for a different key code must not trigger a cancel")
    }

    // MARK: - EdgeDetector unit behavior

    func testEdgeDetectorSuppressesRepeatsAndNilReadings() {
        var detector = EdgeDetector()
        XCTAssertEqual(detector.update(with: true), .press)
        XCTAssertNil(detector.update(with: true), "Re-asserting true is not a new edge")
        XCTAssertNil(detector.update(with: nil), "An irrelevant event leaves state untouched")
        XCTAssertEqual(detector.update(with: false), .release)
        XCTAssertNil(detector.update(with: false))
    }
}
