import XCTest
@testable import VoiceType

/// `ClipboardPaster` driven with a fake pasteboard, a fake ⌘V poster and a
/// manual clock (`DeliveryFakes.swift`): no `NSPasteboard`, no `CGEvent`, no run loop.
final class ClipboardPasterTests: XCTestCase {

    // MARK: - Fixtures

    /// The user's own clipboard before dictating: two items, several types each.
    private let original = ClipboardSnapshot(items: [
        .init([
            .init(type: "public.utf8-plain-text", data: Data("hello".utf8)),
            .init(type: "public.rtf", data: Data("{\\rtf1 hello}".utf8)),
            .init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])),
        ]),
        .init([
            .init(type: "public.file-url", data: Data("file:///tmp/a.txt".utf8)),
            .init(type: "com.example.private", data: Data([0x01, 0x02])),
        ]),
    ])

    private var pasteboard: FakePasteboard!
    private var keys: FakeKeyPoster!
    private var clock: ManualClock!
    private var paster: ClipboardPaster!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard(original)
        keys = FakeKeyPoster()
        clock = ManualClock()
        paster = ClipboardPaster(pasteboard: pasteboard, keyPoster: keys, clock: clock)
    }

    // MARK: - Single paste

    func testPasteWritesTextPostsCommandVThenRestoresOriginal() {
        var textAtPaste: String?
        keys.onPaste = { [unowned self] in textAtPaste = self.pasteboard.text }

        paster.paste("dictated")

        XCTAssertEqual(keys.pastes, 1)
        XCTAssertEqual(textAtPaste, "dictated", "⌘V must be posted after the text is on the pasteboard")
        XCTAssertTrue(paster.isRestorePending)
        XCTAssertEqual(pasteboard.restores, [], "No restore before the delay")

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)

        XCTAssertEqual(pasteboard.restores, [original])
        XCTAssertEqual(pasteboard.contents, original)
        XCTAssertFalse(paster.isRestorePending)
    }

    func testEmptyTextIsANoOp() {
        paster.paste("")
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertFalse(paster.isRestorePending)
    }

    // MARK: - Burst

    func testBurstOfThreeRestoresOriginalOnceAfterTheLastPaste() {
        let half = ClipboardPaster.Timing.restoreDelay / 2

        paster.paste("one")
        clock.advance(by: half)
        paster.paste("two")
        clock.advance(by: half)
        paster.paste("three")

        XCTAssertEqual(keys.pastes, 3)
        XCTAssertEqual(pasteboard.snapshotsTaken, 1, "Only the burst's first paste snapshots the user's clipboard")
        XCTAssertEqual(pasteboard.restores, [], "Earlier pastes' restores are superseded")

        clock.advance(by: ClipboardPaster.Timing.restoreDelay - 0.01)
        XCTAssertEqual(pasteboard.restores, [], "Restore waits a full delay after the LAST paste")

        clock.advance(by: 0.01)
        XCTAssertEqual(pasteboard.restores, [original], "Exactly one restore, of the original clipboard")
        XCTAssertEqual(clock.live.count, 0)
    }

    func testPasteAfterRestoreStartsAFreshBurst() {
        paster.paste("one")
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        pasteboard.externalCopy("copied later")
        let later = pasteboard.contents

        paster.paste("two")
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)

        XCTAssertEqual(pasteboard.restores, [original, later])
    }

    func testExternalCopyMidBurstBecomesTheNewOrigin() {
        paster.paste("one")
        pasteboard.externalCopy("user copied this")
        let userCopy = pasteboard.contents

        paster.paste("two")
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)

        XCTAssertEqual(pasteboard.restores, [userCopy],
                       "The user's newer copy, not the stale original, is what they expect back")
    }

    // MARK: - changeCount guard

    func testRestoreSkippedWhenClipboardChangedSinceOurWrite() {
        paster.paste("dictated")
        pasteboard.externalCopy("user copied this")

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)

        XCTAssertEqual(pasteboard.restores, [], "Never clobber something copied after our write")
        XCTAssertEqual(pasteboard.text, "user copied this")
        XCTAssertFalse(paster.isRestorePending)
    }

    // MARK: - Copy only

    func testCopyOnlyLeavesTextAndNeverRestores() {
        paster.copyOnly("keep me")

        XCTAssertEqual(pasteboard.text, "keep me")
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertFalse(paster.isRestorePending)
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay * 2)
        XCTAssertEqual(pasteboard.restores, [])
    }

    func testCopyOnlyCancelsPendingRestore() {
        paster.paste("pasted")
        paster.copyOnly("keep me")

        XCTAssertFalse(paster.isRestorePending)
        XCTAssertEqual(clock.live.count, 0, "Pending restore timer is cancelled")
        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay * 2)

        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.text, "keep me")
    }

    func testPasteAfterCopyOnlySnapshotsTheCopiedText() {
        paster.paste("pasted")
        paster.copyOnly("keep me")
        let kept = pasteboard.contents

        paster.paste("next")
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)

        XCTAssertEqual(pasteboard.restores, [kept])
    }

    // MARK: - Slow (Electron) apps

    func testSlowAppWaitsLongerBeforeRestoring() {
        XCTAssertGreaterThan(ClipboardPaster.Timing.slowAppRestoreDelay, ClipboardPaster.Timing.restoreDelay)

        paster.paste("dictated", slowApp: true)
        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [], "A slow app may not have read the pasteboard yet")
        XCTAssertEqual(pasteboard.text, "dictated")

        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay - ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testFastPasteNeverShortensASlowPastesPendingRestore() {
        paster.paste("slow", slowApp: true)
        clock.advance(by: 0.1)
        paster.paste("fast")

        clock.advance(by: ClipboardPaster.Timing.restoreDelay)
        XCTAssertEqual(pasteboard.restores, [], "The slow app may still be reading")

        clock.advance(by: ClipboardPaster.Timing.slowAppRestoreDelay)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    // MARK: - Snapshot model

    func testFakeRoundTripsMultiItemMultiTypeAndEmpty() {
        let fake = FakePasteboard()
        fake.restore(original)
        XCTAssertEqual(fake.snapshot(), original)
        fake.restore(.empty)
        XCTAssertEqual(fake.snapshot(), .empty)
        XCTAssertTrue(ClipboardSnapshot.empty.isEmpty)
    }
}
