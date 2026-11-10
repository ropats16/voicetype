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
        delivery = TextDelivery(paster: ClipboardPaster(clipboard: pasteboard, keyPoster: keys, clock: clock),
                                probe: probe)
        // The target app reads the pasteboard while handling ⌘V.
        keys.onPaste = { [unowned self] in self.pasteboard.read() }
    }

    private typealias Timing = ClipboardPaster.Timing

    private func focus(_ focused: FocusObservation.Focused, app: String? = "com.apple.TextEdit",
                       chromium: Bool = false) {
        probe.observation = FocusObservation(focused: focused, bundleID: app, isChromiumHosted: chromium)
    }

    // MARK: - Outcomes

    func testEditableFieldIsPastedThenClipboardRestored() {
        var textAtPaste: String?
        keys.onPaste = { [unowned self] in textAtPaste = self.pasteboard.read() }

        let report = delivery.deliver(" Hello world. ", trailingSpace: false)

        XCTAssertEqual(report, .pasted("Hello world."))
        XCTAssertEqual(keys.pastes, 1)
        XCTAssertEqual(textAtPaste, "Hello world.")
        clock.advance(by: Timing.native.base)
        XCTAssertEqual(pasteboard.contents, original)
    }

    func testUnknownFocusIsPastedAnyway() {
        focus(.none)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false), .pasted("hi"))
        XCTAssertEqual(keys.pastes, 1)
    }

    func testNotEditableIsCopiedWithoutPasteOrRestore() {
        focus(.element(role: "AXButton", valueSettable: false))

        let report = delivery.deliver("hi", trailingSpace: false)

        XCTAssertEqual(report, .copied("hi"))
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertEqual(pasteboard.text, "hi")
        clock.advance(by: Timing.slowApp.cap * 2)
        XCTAssertEqual(pasteboard.restores, [], "The copied text stays for the user")
    }

    func testCopyCancelsPendingRestoreOfEarlierPaste() {
        _ = delivery.deliver("first", trailingSpace: false)
        focus(.element(role: "AXGroup", valueSettable: false))

        XCTAssertEqual(delivery.deliver("second", trailingSpace: false), .copied("second"))

        clock.advance(by: Timing.slowApp.cap * 2)
        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.text, "second")
    }

    func testEmptyTextIsDroppedWithoutTouchingAnything() {
        for raw in ["", "  \n ", "[BLANK_AUDIO]", " (music) ", "[Music] [Applause]", "[Music]\n(laughs)", "♪"] {
            XCTAssertEqual(delivery.deliver(raw, trailingSpace: true), .droppedEmpty, raw)
        }
        XCTAssertEqual(probe.observations, 0, "No AX round-trip for nothing")
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertEqual(pasteboard.changeCount, 0)
    }

    // MARK: - Cleanup

    func testTagsStrippedAnywhere() {
        let report = delivery.deliver("[Music] Hello [MUSIC] world (laughs). ♪", trailingSpace: false)
        XCTAssertEqual(report, .pasted("Hello world."))
        XCTAssertEqual(pasteboard.text, "Hello world.")
    }

    func testSpokenParenthesesKept() {
        XCTAssertEqual(delivery.deliver("Call me (maybe)", trailingSpace: false), .pasted("Call me (maybe)"))
        XCTAssertEqual(delivery.deliver("[unclosed", trailingSpace: false), .pasted("[unclosed"))
    }

    func testTrailingSpaceAppendedWhenAsked() {
        XCTAssertEqual(delivery.deliver(" Hi there.", trailingSpace: true), .pasted("Hi there. "))
        XCTAssertEqual(pasteboard.text, "Hi there. ")
        XCTAssertEqual(delivery.deliver("  Hi there. \n", trailingSpace: false), .pasted("Hi there."))
        XCTAssertEqual(delivery.deliver("[Music] hello [Music]", trailingSpace: true), .pasted("hello "))
    }

    // MARK: - Restore timing

    func testChromiumAppGetsTheSlowRestore() {
        focus(.element(role: "AXTextArea", valueSettable: true), app: "com.microsoft.VSCode", chromium: true)

        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false), .pasted("hi"))

        clock.advance(by: Timing.native.base)
        XCTAssertEqual(pasteboard.text, "hi", "Electron may still be reading the pasteboard")
        clock.advance(by: Timing.slowApp.base - Timing.native.base)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testTimedOutProbePastesWithTheSlowRestore() {
        focus(.timedOut)

        keys.onPaste = nil   // hung: doesn't read while handling ⌘V
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false), .pasted("hi"))

        clock.advance(by: Timing.native.cap)
        XCTAssertEqual(pasteboard.restores, [], "An unread slow paste waits the slow cap")
        clock.advance(by: Timing.slowApp.cap - Timing.native.cap + 0.01)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testBurstRestoresOnceAfterTheLastPaste() {
        focus(.element(role: "AXTextArea", valueSettable: true), chromium: true)
        _ = delivery.deliver("one", trailingSpace: false)
        clock.advance(by: 0.5)
        focus(.element(role: "AXTextField", valueSettable: true))
        _ = delivery.deliver("two", trailingSpace: false)

        clock.advance(by: Timing.native.base)
        XCTAssertEqual(pasteboard.restores, [], "The Electron paste is still within its window")
        clock.advance(by: Timing.slowApp.base)
        XCTAssertEqual(pasteboard.restores, [original], "One restore, of the clipboard before the burst")
    }

    // MARK: - Finder

    func testFinderDesktopCopies() {
        focus(.none, app: FocusRules.finderBundleID)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false), .copied("hi"))
        XCTAssertEqual(keys.pastes, 0)
    }

    func testFinderRenameFieldPastes() {
        focus(.element(role: "AXTextField", valueSettable: true), app: FocusRules.finderBundleID)
        XCTAssertEqual(delivery.deliver("hi", trailingSpace: false), .pasted("hi"))
    }

    // MARK: - Late reader

    func testElectronReadingLateStillPastesTheDictation() {
        focus(.element(role: "AXTextArea", valueSettable: true), app: "com.microsoft.VSCode", chromium: true)
        keys.onPaste = nil

        _ = delivery.deliver("hi", trailingSpace: false)
        clock.advance(by: 1.5)   // past the old fixed 1 s
        XCTAssertEqual(pasteboard.read(), "hi")
        clock.advance(by: Timing.readGrace + 0.01)
        XCTAssertEqual(pasteboard.restores, [original])
    }
}
