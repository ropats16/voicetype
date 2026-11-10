import XCTest
@testable import VoiceType

/// `TextDelivery` driven end to end with a fake pasteboard, focus probe, ⌘V
/// poster and a manual clock (`DeliveryFakes.swift`).
final class TextDeliveryTests: XCTestCase {

    private let original = ClipboardSnapshot(items: [
        .init([
            .init(type: "public.utf8-plain-text", data: Data("mine".utf8)),
            .init(type: "public.rtf", data: Data("{\\rtf1 mine}".utf8)),
        ]),
        .init([.init(type: "public.png", data: Data([0x89, 0x50]))]),
    ])

    private var pasteboard: FakePasteboard!
    private var keys: FakeKeyPoster!
    private var clock: ManualClock!
    private var probe: FakeFocusProbe!
    private var delivery: TextDelivery!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard(original)
        keys = FakeKeyPoster()
        clock = ManualClock()
        probe = FakeFocusProbe()
        delivery = TextDelivery(paster: ClipboardPaster(pasteboard: pasteboard, keyPoster: keys, clock: clock),
                                probe: probe)
    }

    private func focus(_ focused: FocusObservation.Focused, app: String? = "com.apple.TextEdit",
                       chromium: Bool = false) {
        probe.observation = FocusObservation(focused: focused, bundleID: app, isChromiumHosted: chromium)
    }

    // MARK: - Outcomes

    func testEditableFieldIsPastedThenClipboardRestored() {
        var textAtPaste: String?
        keys.onPaste = { [unowned self] in textAtPaste = self.pasteboard.text }

        let report = delivery.deliver(" Hello world. ", trailingSpace: false)

        XCTAssertEqual(report, DeliveryReport(outcome: .pasted, text: "Hello world."))
        XCTAssertEqual(keys.pastes, 1)
        XCTAssertEqual(textAtPaste, "Hello world.")
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.contents, original)
    }

    func testUnknownFocusIsPastedAnyway() {
        focus(.none)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false).outcome, .pasted)
        XCTAssertEqual(keys.pastes, 1)
    }

    func testNotEditableIsCopiedWithoutPasteOrRestore() {
        focus(.element(role: "AXButton", valueSettable: false))

        let report = delivery.deliver("hi", trailingSpace: false)

        XCTAssertEqual(report, DeliveryReport(outcome: .copied, text: "hi"))
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertEqual(pasteboard.text, "hi")
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay * 2)
        XCTAssertEqual(pasteboard.restores, [], "The copied text stays for the user")
    }

    func testCopyCancelsPendingRestoreOfEarlierPaste() {
        delivery.deliver("first", trailingSpace: false)
        focus(.element(role: "AXGroup", valueSettable: false))

        XCTAssertEqual(delivery.deliver("second", trailingSpace: false).outcome, .copied)

        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay * 2)
        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.text, "second")
    }

    func testEmptyTextIsDroppedWithoutTouchingAnything() {
        for raw in ["", "  \n ", "[BLANK_AUDIO]", " (music) ", "[Music] [Applause]", "[Music]\n(laughs)", "♪"] {
            XCTAssertEqual(delivery.deliver(raw, trailingSpace: true), DeliveryReport(outcome: .droppedEmpty, text: ""),
                           raw)
        }
        XCTAssertEqual(probe.observations, 0, "No AX round-trip for nothing")
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertEqual(pasteboard.changeCount, 0)
    }

    // MARK: - Cleanup

    func testTagsStrippedAnywhere() {
        let report = delivery.deliver("[Music] Hello [MUSIC] world (laughs). ♪", trailingSpace: false)
        XCTAssertEqual(report.text, "Hello world.")
        XCTAssertEqual(pasteboard.text, "Hello world.")
    }

    func testSpokenParenthesesKept() {
        XCTAssertEqual(delivery.deliver("Call me (maybe)", trailingSpace: false).text, "Call me (maybe)")
        XCTAssertEqual(delivery.deliver("[unclosed", trailingSpace: false).text, "[unclosed")
    }

    func testTrailingSpaceAppendedWhenAsked() {
        XCTAssertEqual(delivery.deliver(" Hi there.", trailingSpace: true).text, "Hi there. ")
        XCTAssertEqual(pasteboard.text, "Hi there. ")
        XCTAssertEqual(delivery.deliver("  Hi there. \n", trailingSpace: false).text, "Hi there.")
        XCTAssertEqual(delivery.deliver("[Music] hello [Music]", trailingSpace: true).text, "hello ")
    }

    // MARK: - Restore timing

    func testChromiumAppGetsTheSlowRestore() {
        focus(.element(role: "AXTextArea", valueSettable: true), app: "com.microsoft.VSCode", chromium: true)

        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false).outcome, .pasted)

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.text, "hi", "Electron may still be reading the pasteboard")
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay - ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testTimedOutProbePastesWithTheSlowRestore() {
        focus(.timedOut)

        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false).outcome, .pasted)

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [])
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testBurstRestoresOnceAfterTheLastPaste() {
        focus(.element(role: "AXTextArea", valueSettable: true), chromium: true)
        delivery.deliver("one", trailingSpace: false)
        clock.advance(by: 0.5)
        focus(.element(role: "AXTextField", valueSettable: true))
        delivery.deliver("two", trailingSpace: false)

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [], "The Electron paste is still within its window")
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay)
        XCTAssertEqual(pasteboard.restores, [original], "One restore, of the clipboard before the burst")
    }

    // MARK: - Finder

    func testFinderDesktopCopies() {
        focus(.none, app: FocusRules.finderBundleID)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false).outcome, .copied)
        XCTAssertEqual(keys.pastes, 0)
    }

    func testFinderRenameFieldPastes() {
        focus(.element(role: "AXTextField", valueSettable: true), app: FocusRules.finderBundleID)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false).outcome, .pasted)
    }
}
