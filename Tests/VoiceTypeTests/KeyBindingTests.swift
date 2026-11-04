import XCTest
import CoreGraphics
@testable import VoiceType

/// Tests for the KeyBinding module, driven entirely through its interface:
/// modifier vocabulary, description, satisfaction, validation, capture, and the
/// hotkey edge state (including the synthetic release on a tap reset). Events
/// are synthetic `KeyEvent`s — no real `CGEventTap` or `NSEvent` is involved.
final class KeyBindingTests: XCTestCase {

    // MARK: - Synthetic event helpers

    private func down(_ keyCode: Int, _ flags: CGEventFlags = [], repeat isRepeat: Bool = false) -> KeyEvent {
        KeyEvent(kind: .keyDown, keyCode: keyCode, flags: flags, isAutorepeat: isRepeat)
    }
    private func up(_ keyCode: Int, _ flags: CGEventFlags = []) -> KeyEvent {
        KeyEvent(kind: .keyUp, keyCode: keyCode, flags: flags)
    }
    private func flagsChanged(_ keyCode: Int, _ flags: CGEventFlags) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    /// NX_DEVICE…KEYMASK bits, as the tap reports them on flagsChanged.
    private let rightOptionBit = CGEventFlags(rawValue: 0x40)
    private let leftOptionBit = CGEventFlags(rawValue: 0x20)

    private let ctrlOptSpace = KeyBinding.controlOptionSpace   // 49, [control, option]
    private let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]

    private func edges(hold: KeyBinding = .controlShift,
                       toggle: KeyBinding = .controlOptionSpace) -> HotkeyEdges {
        HotkeyEdges(hold: hold, toggle: toggle, cancelKeyCode: KeyBinding.escapeKeyCode)
    }

    /// Feeds events through a capture session; returns the first non-pending outcome.
    private func capture(_ events: [KeyEvent]) -> KeyBinding.Capture.Outcome {
        var session = KeyBinding.Capture()
        for event in events {
            let outcome = session.handle(event)
            if outcome != .pending { return outcome }
        }
        return .pending
    }

    // MARK: - Modifier vocabulary (aliases, case)

    func testModifierAliasesResolveToCanonicalModifiers() {
        let cases: [(String, KeyBinding.Modifier)] = [
            ("command", .command), ("cmd", .command),
            ("option", .option), ("alt", .option),
            ("control", .control), ("ctrl", .control),
            ("shift", .shift),
            ("function", .function), ("fn", .function), ("globe", .function),
            ("Control", .control), ("SHIFT", .shift),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(KeyBinding.Modifier(name: name), expected, name)
        }
        XCTAssertNil(KeyBinding.Modifier(name: "controll"))
    }

    func testAliasedConfigBindingIsSatisfiedLikeCanonical() {
        // Hand-edited configs use aliases; they must keep working at runtime.
        let aliased = KeyBinding(keyCode: -1, modifiers: ["ctrl", "Shift"])
        XCTAssertEqual(aliased.satisfaction(by: flagsChanged(-1, [.maskControl, .maskShift])), true)
        XCTAssertEqual(aliased.satisfaction(by: flagsChanged(-1, [.maskControl])), false)
    }

    // MARK: - Satisfaction: regular key + modifiers (the ⌃⌥Space fix)

    func testRegularKeySatisfiedWhenBothModifiersPresent() {
        XCTAssertEqual(ctrlOptSpace.satisfaction(by: down(49, ctrlOpt)), true,
                       "⌃⌥Space must be satisfied on keyDown when both control and option are held")
    }

    func testRegularKeyNotSatisfiedWhenModifierMissing() {
        // The old keyCode-only path would have (wrongly) fired here.
        XCTAssertEqual(ctrlOptSpace.satisfaction(by: down(49, [.maskControl])), false)
    }

    func testRegularKeyNotSatisfiedOnKeyUp() {
        XCTAssertEqual(ctrlOptSpace.satisfaction(by: up(49, ctrlOpt)), false)
    }

    func testRegularKeyIrrelevantForOtherKeyCode() {
        XCTAssertNil(ctrlOptSpace.satisfaction(by: down(48, ctrlOpt)))
    }

    func testRegularKeyIrrelevantOnFlagsChanged() {
        XCTAssertNil(ctrlOptSpace.satisfaction(by: flagsChanged(49, ctrlOpt)))
    }

    func testRegularKeyAutorepeatIsIrrelevant() {
        XCTAssertNil(ctrlOptSpace.satisfaction(by: down(49, ctrlOpt, repeat: true)),
                     "An autorepeat keyDown is a still-held key, not a fresh press")
    }

    // MARK: - Satisfaction: pure-modifier combo and single modifier

    func testComboUnsatisfiedUntilEveryModifierHeld() {
        XCTAssertEqual(KeyBinding.controlShift.satisfaction(by: flagsChanged(-1, [.maskControl])), false)
        XCTAssertEqual(KeyBinding.controlShift.satisfaction(by: flagsChanged(-1, [.maskControl, .maskShift])), true)
        XCTAssertNil(KeyBinding.controlShift.satisfaction(by: down(0, [.maskControl, .maskShift])),
                     "Only flagsChanged pertains to a pure-modifier combo")
    }

    func testSingleModifierUsesDeviceBit() {
        let rightOption = KeyBinding.rightOption
        XCTAssertEqual(rightOption.satisfaction(by: flagsChanged(61, rightOptionBit.union(.maskAlternate))), true)
        XCTAssertEqual(rightOption.satisfaction(by: flagsChanged(61, [])), false)
        XCTAssertNil(rightOption.satisfaction(by: flagsChanged(58, leftOptionBit.union(.maskAlternate))),
                     "Left Option must not pertain to Right Option")
    }

    // MARK: - Description

    func testDescriptions() {
        XCTAssertEqual(KeyBinding.controlShift.description, "⌃ ⇧")
        XCTAssertEqual(KeyBinding.controlOptionSpace.description, "⌃⌥Space")
        XCTAssertEqual(KeyBinding.rightOption.description, "Right ⌥")
        XCTAssertEqual(KeyBinding(keyCode: 59, modifiers: []).description, "Left ⌃")
        XCTAssertEqual(KeyBinding(keyCode: 53, modifiers: []).description, "Esc")
        XCTAssertEqual(KeyBinding(keyCode: 36, modifiers: ["command"]).description, "⌘key36")
    }

    func testDescriptionUnderstandsAliasesInCanonicalOrder() {
        XCTAssertEqual(KeyBinding(keyCode: -1, modifiers: ["Shift", "ctrl"]).description, "⌃ ⇧")
        XCTAssertEqual(KeyBinding(keyCode: 49, modifiers: ["alt", "cmd"]).description, "⌥⌘Space")
        XCTAssertEqual(KeyBinding.fnShift.description, "⇧ fn")
    }

    // MARK: - Validation

    func testEmptyBindingIsUnmatchable() {
        XCTAssertTrue(KeyBinding(keyCode: -1, modifiers: []).isUnmatchable)
        XCTAssertFalse(KeyBinding.controlShift.isUnmatchable)
        XCTAssertFalse(KeyBinding.rightOption.isUnmatchable)
    }

    func testUnknownModifiersAreReportedVerbatim() {
        XCTAssertEqual(KeyBinding(keyCode: -1, modifiers: ["controll", "shift"]).unknownModifiers, ["controll"])
        XCTAssertEqual(KeyBinding(keyCode: -1, modifiers: ["Control", "SHIFT", "cmd", "globe"]).unknownModifiers, [])
    }

    func testSameChordIgnoresOrderCaseAndAliases() {
        let a = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        XCTAssertTrue(a.isSameChord(as: KeyBinding(keyCode: -1, modifiers: ["shift", "control"])))
        XCTAssertTrue(a.isSameChord(as: KeyBinding(keyCode: -1, modifiers: ["Shift", "ctrl"])))
        XCTAssertFalse(a.isSameChord(as: KeyBinding(keyCode: -1, modifiers: ["control", "option"])))
        XCTAssertFalse(KeyBinding.controlOptionSpace.isSameChord(as: KeyBinding(keyCode: 48, modifiers: ["control", "option"])))
    }

    // MARK: - Capture → binding

    func testCaptureRegularKeyWithModifiers() {
        XCTAssertEqual(capture([flagsChanged(59, [.maskControl]),
                                flagsChanged(58, ctrlOpt),
                                down(49, ctrlOpt)]),
                       .captured(KeyBinding(keyCode: 49, modifiers: ["control", "option"])))
    }

    func testCaptureRegularKeyAlone() {
        XCTAssertEqual(capture([down(36)]), .captured(KeyBinding(keyCode: 36, modifiers: [])))
    }

    func testCaptureEscCancels() {
        XCTAssertEqual(capture([down(53)]), .cancelled)
    }

    func testCaptureIgnoresAutorepeatAndOtherFlags() {
        // Caps Lock (maskAlphaShift) is not a binding modifier.
        var session = KeyBinding.Capture()
        XCTAssertEqual(session.handle(down(5, [.maskShift], repeat: true)), .pending)
        XCTAssertEqual(session.handle(down(5, [.maskShift, .maskAlphaShift])),
                       .captured(KeyBinding(keyCode: 5, modifiers: ["shift"])))
    }

    func testCaptureModifierComboOnReleaseInCanonicalOrder() {
        // Pressed command then shift then option; released in any order.
        XCTAssertEqual(capture([flagsChanged(55, [.maskCommand]),
                                flagsChanged(56, [.maskCommand, .maskShift]),
                                flagsChanged(58, [.maskCommand, .maskShift, .maskAlternate]),
                                flagsChanged(55, [.maskShift, .maskAlternate]),
                                flagsChanged(56, [.maskAlternate]),
                                flagsChanged(58, [])]),
                       .captured(KeyBinding(keyCode: -1, modifiers: ["option", "shift", "command"])))
    }

    func testCaptureSingleModifierKeepsSide() {
        XCTAssertEqual(capture([flagsChanged(61, rightOptionBit.union(.maskAlternate)),
                                flagsChanged(61, [])]),
                       .captured(.rightOption))
    }

    func testCaptureSingleModifierRemembersKeyThatGrewTheSet() {
        // Left ⌃ down, Right ⌃ down (held set unchanged), Right ⌃ up, Left ⌃ up:
        // only a key that grew the held set may become the single-modifier key.
        XCTAssertEqual(capture([flagsChanged(59, [.maskControl]),
                                flagsChanged(62, [.maskControl]),
                                flagsChanged(62, [.maskControl]),
                                flagsChanged(59, [])]),
                       .captured(KeyBinding(keyCode: 59, modifiers: [])))
    }

    func testCaptureNonSidedSingleModifierKeepsWaiting() {
        // fn alone (key code 63) has no device bit, so it can't be a single-modifier hold.
        var session = KeyBinding.Capture()
        XCTAssertEqual(session.handle(flagsChanged(63, [.maskSecondaryFn])), .pending)
        XCTAssertEqual(session.handle(flagsChanged(63, [])), .pending)
        XCTAssertEqual(session.handle(down(49)), .captured(KeyBinding(keyCode: 49, modifiers: [])),
                       "After a failed attempt the session resets and keeps capturing")
    }

    // MARK: - Round trips: capture → binding → description → satisfaction

    /// Captures `events`, checks the description, then replays `pressEvents`
    /// and `releaseEvents` (as the tap would deliver them) through a hold edge
    /// tracker and expects exactly one start and one stop.
    private func assertRoundTrip(capturing events: [KeyEvent],
                                 describedAs label: String,
                                 press pressEvents: [KeyEvent],
                                 release releaseEvents: [KeyEvent],
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard case .captured(let binding) = capture(events) else {
            return XCTFail("capture did not produce a binding", file: file, line: line)
        }
        XCTAssertEqual(binding.description, label, file: file, line: line)

        // Persisted and reloaded, as Settings → config.json → app launch does.
        let reloaded = try! JSONDecoder().decode(KeyBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(reloaded, binding, file: file, line: line)

        var state = HotkeyEdges(hold: reloaded, toggle: KeyBinding(keyCode: 122, modifiers: []),
                                cancelKeyCode: KeyBinding.escapeKeyCode)
        XCTAssertEqual(pressEvents.flatMap { state.handle($0) }, [.holdStart], file: file, line: line)
        XCTAssertEqual(releaseEvents.flatMap { state.handle($0) }, [.holdStop], file: file, line: line)
    }

    func testRoundTripModifierCombo() {
        let both: CGEventFlags = [.maskControl, .maskShift]
        assertRoundTrip(
            capturing: [flagsChanged(59, [.maskControl]), flagsChanged(56, both),
                        flagsChanged(56, [.maskControl]), flagsChanged(59, [])],
            describedAs: "⌃ ⇧",
            press: [flagsChanged(59, [.maskControl]), flagsChanged(56, both)],
            release: [flagsChanged(56, [.maskControl]), flagsChanged(59, [])])
    }

    func testRoundTripSingleModifier() {
        let held = rightOptionBit.union(.maskAlternate)
        assertRoundTrip(
            capturing: [flagsChanged(61, held), flagsChanged(61, [])],
            describedAs: "Right ⌥",
            press: [flagsChanged(58, leftOptionBit.union(.maskAlternate)), flagsChanged(58, []),
                    flagsChanged(61, held)],
            release: [flagsChanged(61, [])])
    }

    func testRoundTripRegularKeyWithModifiers() {
        assertRoundTrip(
            capturing: [flagsChanged(59, [.maskControl]), flagsChanged(58, ctrlOpt), down(49, ctrlOpt)],
            describedAs: "⌃⌥Space",
            press: [flagsChanged(59, [.maskControl]), down(49, [.maskControl]),   // option missing
                    flagsChanged(58, ctrlOpt), down(49, ctrlOpt), down(49, ctrlOpt, repeat: true)],
            release: [up(49, ctrlOpt)])
    }

    // MARK: - Hotkey edges

    func testHoldComboEdges() {
        var state = edges()
        XCTAssertEqual(state.handle(flagsChanged(59, [.maskControl])), [])
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl, .maskShift])), [.holdStart])
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl, .maskShift])), [],
                       "Re-asserting a held combo is not a new press")
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl])), [.holdStop])
    }

    func testToggleFiresOncePerPhysicalPress() {
        var state = edges()
        let sequence = [down(49, ctrlOpt), down(49, ctrlOpt, repeat: true), down(49, ctrlOpt, repeat: true),
                        up(49, ctrlOpt), down(49, ctrlOpt)]
        XCTAssertEqual(sequence.flatMap { state.handle($0) }, [.togglePress, .togglePress])
    }

    func testCancelKeyFiresOnFreshKeyDownOnly() {
        var state = edges()
        XCTAssertEqual(state.handle(down(53)), [.cancel])
        XCTAssertEqual(state.handle(down(53, repeat: true)), [])
        XCTAssertEqual(state.handle(up(53)), [])
        XCTAssertEqual(state.handle(down(49)), [], "Space alone is neither toggle nor cancel")
    }

    // MARK: - Tap reset while held → synthetic release

    func testResetWhileHoldActiveEmitsRelease() {
        var state = edges()
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl, .maskShift])), [.holdStart])
        XCTAssertEqual(state.reset(), [.holdStop],
                       "A tap reset mid-hold may have dropped the release; recording must not run to the cap")
        // The real release now arrives (or never does): no second stop.
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl])), [])
        XCTAssertEqual(state.handle(flagsChanged(59, [])), [])
    }

    func testResetWhileIdleEmitsNothing() {
        var state = edges()
        XCTAssertEqual(state.reset(), [])
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskShift])), [])
        XCTAssertEqual(state.reset(), [])
    }

    func testResetWhileToggleKeyHeldEmitsNothingAndRearmsToggle() {
        var state = edges()
        XCTAssertEqual(state.handle(down(49, ctrlOpt)), [.togglePress])
        XCTAssertEqual(state.reset(), [], "Toggle fires on press only; a reset is not a press")
        XCTAssertEqual(state.handle(down(49, ctrlOpt)), [.togglePress],
                       "A missed keyUp must not swallow the next physical press")
    }

    func testHoldCanRestartAfterReset() {
        var state = edges()
        _ = state.handle(flagsChanged(56, [.maskControl, .maskShift]))
        _ = state.reset()
        XCTAssertEqual(state.handle(flagsChanged(56, [.maskControl, .maskShift])), [.holdStart])
    }
}
