import XCTest
@testable import VoiceType

/// `ClipboardPaster` driven with a fake pasteboard, a fake ⌘V poster and a
/// manual clock (`DeliveryFakes.swift`): no `NSPasteboard`, no `CGEvent`, no run loop.
final class ClipboardPasterTests: XCTestCase {
    private typealias Timing = ClipboardPaster.Timing

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

    /// Keeps assertions off exact float boundaries.
    private let tick: TimeInterval = 0.01

    private var pasteboard: FakePasteboard!
    private var keys: FakeKeyPoster!
    private var clock: ManualClock!
    private var paster: ClipboardPaster!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard(original)
        keys = FakeKeyPoster()
        clock = ManualClock()
        paster = ClipboardPaster(clipboard: pasteboard, keyPoster: keys, clock: clock)
        // By default the target is a native app that reads while handling ⌘V.
        keys.onPaste = { [unowned self] in self.pasteboard.read() }
    }

    /// The target hasn't read by the time ⌘V returns (slow, hung, or ⌘V hit nothing).
    private func targetReadsLate() { keys.onPaste = nil }

    // MARK: - Single paste

    func testPasteWritesTextPostsCommandVThenRestoresOriginal() {
        var textAtPaste: String?
        keys.onPaste = { [unowned self] in textAtPaste = self.pasteboard.read() }

        paster.paste("dictated")

        XCTAssertEqual(keys.pastes, 1)
        XCTAssertEqual(textAtPaste, "dictated", "⌘V must be posted after the text is on the pasteboard")
        XCTAssertTrue(paster.isRestorePending)
        XCTAssertEqual(pasteboard.restores, [], "No restore before the delay")

        clock.advance(by: Timing.native.base)

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

    // MARK: - Read-driven restore

    func testEarlyReadStillWaitsTheBaseDelay() {
        // A clipboard manager polling changeCount may be the first reader, long
        // before the target app: an early read never restores before the base.
        targetReadsLate()
        paster.paste("dictated")
        clock.advance(by: tick)
        pasteboard.read()

        clock.advance(by: Timing.native.base - 2 * tick)
        XCTAssertEqual(pasteboard.restores, [])
        clock.advance(by: 2 * tick)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testLateReadDefersRestoreUntilReadPlusGrace() {
        targetReadsLate()
        paster.paste("dictated")

        clock.advance(by: Timing.native.base + 0.5)
        XCTAssertEqual(pasteboard.restores, [], "Not read yet: the app would paste the old clipboard")

        XCTAssertEqual(pasteboard.read(), "dictated")
        clock.advance(by: Timing.readGrace - tick)
        XCTAssertEqual(pasteboard.restores, [], "The reader may still be mid-paste")
        clock.advance(by: 2 * tick)
        XCTAssertEqual(pasteboard.restores, [original])
        XCTAssertEqual(clock.live.count, 0)
    }

    func testSlowAppReadingPastTheOldFixedDelayGetsItsText() {
        targetReadsLate()
        paster.paste("dictated", slowApp: true)

        clock.advance(by: Timing.slowApp.base + 0.5)
        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.read(), "dictated", "A busy Electron renderer reading at 1.5 s gets the dictation")

        clock.advance(by: Timing.readGrace + tick)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testUnreadPasteRestoresAtTheCap() {
        targetReadsLate()
        paster.paste("dictated")

        clock.advance(by: Timing.native.cap - tick)
        XCTAssertEqual(pasteboard.restores, [])
        clock.advance(by: 2 * tick)
        XCTAssertEqual(pasteboard.restores, [original])
        XCTAssertFalse(paster.isRestorePending)
    }

    func testUnreadSlowAppPasteWaitsTheLongerCap() {
        XCTAssertGreaterThan(Timing.slowApp.cap, Timing.native.cap)
        targetReadsLate()
        paster.paste("dictated", slowApp: true)

        clock.advance(by: Timing.slowApp.cap - tick)
        XCTAssertEqual(pasteboard.restores, [])
        clock.advance(by: 2 * tick)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testTimingValuesAreOrdered() {
        for pace in [Timing.native, Timing.slowApp] {
            XCTAssertLessThan(pace.base, pace.cap)
        }
        XCTAssertGreaterThan(Timing.slowApp.base, Timing.native.base)
        XCTAssertGreaterThan(Timing.readGrace, 0)
    }

    func testReadOfASupersededWriteIsIgnored() {
        targetReadsLate()
        paster.paste("one")
        paster.paste("two")

        pasteboard.readHooks[0]()   // a stale read of "one" must not arm the restore of "two"
        clock.advance(by: Timing.native.base + Timing.readGrace + tick)
        XCTAssertEqual(pasteboard.restores, [], "\"two\" hasn't been read yet")

        clock.advance(by: Timing.native.cap)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testEachPasteOfABurstNeedsItsOwnRead() {
        paster.paste("one")            // read at ⌘V
        targetReadsLate()
        paster.paste("two")            // not read

        clock.advance(by: Timing.native.base + tick)
        XCTAssertEqual(pasteboard.restores, [], "The read of \"one\" says nothing about \"two\"")
        pasteboard.read()
        clock.advance(by: Timing.readGrace + tick)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testReadDrivenRestoreKeepsTheChangeCountGuard() {
        targetReadsLate()
        paster.paste("dictated")
        clock.advance(by: 1)
        pasteboard.read()
        pasteboard.externalCopy("user copied this")

        clock.advance(by: Timing.native.cap)
        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.text, "user copied this")
    }

    // MARK: - Burst

    func testBurstOfThreeRestoresOriginalOnceAfterTheLastPaste() {
        let half = Timing.native.base / 2

        paster.paste("one")
        clock.advance(by: half)
        paster.paste("two")
        clock.advance(by: half)
        paster.paste("three")

        XCTAssertEqual(keys.pastes, 3)
        XCTAssertEqual(pasteboard.snapshotsTaken, 1, "Only the burst's first paste snapshots the user's clipboard")
        XCTAssertEqual(pasteboard.restores, [], "Earlier pastes' restores are superseded")

        clock.advance(by: Timing.native.base - tick)
        XCTAssertEqual(pasteboard.restores, [], "Restore waits a full delay after the LAST paste")

        clock.advance(by: tick)
        XCTAssertEqual(pasteboard.restores, [original], "Exactly one restore, of the original clipboard")
        XCTAssertEqual(clock.live.count, 0)
    }

    func testPasteAfterRestoreStartsAFreshBurst() {
        paster.paste("one")
        clock.advance(by: Timing.native.base)
        pasteboard.externalCopy("copied later")
        let later = pasteboard.contents

        paster.paste("two")
        clock.advance(by: Timing.native.base)

        XCTAssertEqual(pasteboard.restores, [original, later])
    }

    func testExternalCopyMidBurstBecomesTheNewOrigin() {
        paster.paste("one")
        pasteboard.externalCopy("user copied this")
        let userCopy = pasteboard.contents

        paster.paste("two")
        clock.advance(by: Timing.native.base)

        XCTAssertEqual(pasteboard.restores, [userCopy],
                       "The user's newer copy, not the stale original, is what they expect back")
    }

    // MARK: - changeCount guard

    func testRestoreSkippedWhenClipboardChangedSinceOurWrite() {
        paster.paste("dictated")
        pasteboard.externalCopy("user copied this")

        clock.advance(by: Timing.native.base)

        XCTAssertEqual(pasteboard.restores, [], "Never clobber something copied after our write")
        XCTAssertEqual(pasteboard.text, "user copied this")
        XCTAssertFalse(paster.isRestorePending)
    }

    // MARK: - Password managers / transient contents

    func testConcealedOrTransientClipboardIsNeverRestored() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let secret = ClipboardSnapshot(items: [.init([
                .init(type: "public.utf8-plain-text", data: Data("hunter2".utf8)),
                .init(type: marker, data: Data()),
            ])])
            pasteboard = FakePasteboard(secret)
            paster = ClipboardPaster(clipboard: pasteboard, keyPoster: keys, clock: clock)
            keys.onPaste = { [unowned self] in self.pasteboard.read() }

            paster.paste("dictated")
            clock.advance(by: Timing.slowApp.cap + 1)

            XCTAssertEqual(pasteboard.restores, [], marker)
            XCTAssertEqual(pasteboard.text, "dictated", "\(marker): the dictation stays, the secret is gone")
            XCTAssertEqual(pasteboard.plainWrites, ["dictated"],
                           "\(marker): rewritten plainly, so it outlives the lazy provider (and us)")
            XCTAssertFalse(paster.isRestorePending, marker)
        }
    }

    func testEphemeralMarkersAreRecognised() {
        XCTAssertFalse(original.isEphemeral)
        XCTAssertFalse(ClipboardSnapshot.empty.isEphemeral)
        let concealed = ClipboardSnapshot(items: [
            .init([.init(type: "public.utf8-plain-text", data: Data("a".utf8))]),
            .init([.init(type: "org.nspasteboard.ConcealedType", data: Data())]),
        ])
        XCTAssertTrue(concealed.isEphemeral, "A marker on any item counts")
    }

    // MARK: - Copy only

    func testCopyOnlyLeavesTextAndNeverRestores() {
        paster.copyOnly("keep me")

        XCTAssertEqual(pasteboard.text, "keep me")
        XCTAssertEqual(keys.pastes, 0)
        XCTAssertFalse(paster.isRestorePending)
        clock.advance(by: Timing.slowApp.cap * 2)
        XCTAssertEqual(pasteboard.restores, [])
    }

    func testCopyOnlyCancelsPendingRestore() {
        paster.paste("pasted")
        paster.copyOnly("keep me")

        XCTAssertFalse(paster.isRestorePending)
        XCTAssertEqual(clock.live.count, 0, "Pending restore timer is cancelled")
        clock.advance(by: Timing.slowApp.cap * 2)

        XCTAssertEqual(pasteboard.restores, [])
        XCTAssertEqual(pasteboard.text, "keep me")
    }

    func testCopyOnlyCancelsAnUnreadPastesRestore() {
        targetReadsLate()
        paster.paste("pasted")
        paster.copyOnly("keep me")
        pasteboard.readHooks[0]()   // a late read of the paste can't revive it

        XCTAssertFalse(paster.isRestorePending)
        clock.advance(by: Timing.slowApp.cap * 2)
        XCTAssertEqual(pasteboard.restores, [])
    }

    func testPasteAfterCopyOnlySnapshotsTheCopiedText() {
        paster.paste("pasted")
        paster.copyOnly("keep me")
        let kept = pasteboard.contents

        paster.paste("next")
        clock.advance(by: Timing.native.base)

        XCTAssertEqual(pasteboard.restores, [kept])
    }

    // MARK: - Slow (Electron) apps

    func testSlowAppWaitsLongerBeforeRestoring() {
        paster.paste("dictated", slowApp: true)
        clock.advance(by: Timing.native.base)
        XCTAssertEqual(pasteboard.restores, [], "Even after a read (maybe a clipboard manager's), wait the slow base")
        XCTAssertEqual(pasteboard.text, "dictated")

        clock.advance(by: Timing.slowApp.base - Timing.native.base)
        XCTAssertEqual(pasteboard.restores, [original])
    }

    func testFastPasteNeverShortensASlowPastesPendingRestore() {
        paster.paste("slow", slowApp: true)
        clock.advance(by: 0.1)
        paster.paste("fast")

        clock.advance(by: Timing.native.base)
        XCTAssertEqual(pasteboard.restores, [], "The slow app may still be reading")

        clock.advance(by: Timing.slowApp.base)
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

    func testFilePromiseTypesAreNotCaptured() {
        for type in ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
                     "com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.promised-file-name",
                     "com.apple.pasteboard.NSFilePromiseID", "Apple files promise pasteboard type"] {
            XCTAssertFalse(ClipboardSnapshot.captures(type: type), type)
        }
        for type in ["public.utf8-plain-text", "public.rtf", "public.file-url", "com.example.private"] {
            XCTAssertTrue(ClipboardSnapshot.captures(type: type), type)
        }
    }
}
