import XCTest
import AppKit
@testable import VoiceType

/// `SystemClipboard` against a real, uniquely named `NSPasteboard` — never
/// the general one, so running tests can't touch the user's clipboard.
final class SystemClipboardTests: XCTestCase {
    private var nsPasteboard: NSPasteboard!
    private var pasteboard: SystemClipboard!

    override func setUp() {
        super.setUp()
        nsPasteboard = NSPasteboard(name: .init("VoiceTypeTests.\(UUID().uuidString)"))
        nsPasteboard.clearContents()
        pasteboard = SystemClipboard(nsPasteboard)
    }

    override func tearDown() {
        nsPasteboard.releaseGlobally()
        super.tearDown()
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
    private let rtf = Data("{\\rtf1\\ansi hello}".utf8)

    func testMultiItemMultiTypeRoundTrips() {
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(rtf, forType: .rtf)
        first.setData(png, forType: .png)
        let second = NSPasteboardItem()
        second.setString(URL(fileURLWithPath: "/tmp/a.txt").absoluteString, forType: .fileURL)
        second.setData(Data([0x01, 0x02, 0x03]), forType: .init("com.example.voicetype.private"))
        XCTAssertTrue(nsPasteboard.writeObjects([first, second]))

        let snapshot = pasteboard.snapshot()
        XCTAssertEqual(snapshot.items.count, 2)
        // Superset: the pasteboard also synthesizes converted types (e.g. utf16 text).
        XCTAssertTrue(Set(snapshot.items[0].representations.map(\.type)).isSuperset(of:
            [NSPasteboard.PasteboardType.string, .rtf, .png].map(\.rawValue)))

        pasteboard.write("dictated")
        XCTAssertEqual(nsPasteboard.string(forType: .string), "dictated")
        XCTAssertNotEqual(pasteboard.snapshot(), snapshot)

        pasteboard.restore(snapshot)

        XCTAssertEqual(pasteboard.snapshot(), snapshot)
        let items = nsPasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "hello")
        XCTAssertEqual(items[0].data(forType: .rtf), rtf)
        XCTAssertEqual(items[0].data(forType: .png), png)
        XCTAssertEqual(items[1].string(forType: .fileURL), URL(fileURLWithPath: "/tmp/a.txt").absoluteString)
    }

    func testEmptyRoundTripsToEmpty() {
        let snapshot = pasteboard.snapshot()
        XCTAssertEqual(snapshot, .empty)

        pasteboard.write("dictated")
        pasteboard.restore(snapshot)

        XCTAssertEqual(pasteboard.snapshot(), .empty)
        XCTAssertNil(nsPasteboard.string(forType: .string))
    }

    func testChangeCountTracksWrites() {
        let before = pasteboard.changeCount
        pasteboard.write("dictated")
        let afterWrite = pasteboard.changeCount
        XCTAssertNotEqual(afterWrite, before)

        nsPasteboard.clearContents()
        nsPasteboard.setString("someone else", forType: .string)
        XCTAssertNotEqual(pasteboard.changeCount, afterWrite)
    }

    // MARK: - Lazy paste write

    func testPasteWriteIsServedLazilyAndReportsItsFirstRead() {
        var reads = 0
        pasteboard.writeForPaste("dictated") { reads += 1 }
        let written = pasteboard.changeCount

        XCTAssertEqual(reads, 0, "Nothing has read it yet")
        XCTAssertTrue(pasteboard.isServingPasteText)
        XCTAssertEqual(nsPasteboard.types?.contains(.string), true, "Promised, not yet provided")

        XCTAssertEqual(nsPasteboard.string(forType: .string), "dictated")
        XCTAssertEqual(reads, 1, "The provider ran: the first read is reported")
        XCTAssertEqual(nsPasteboard.string(forType: .string), "dictated")
        XCTAssertEqual(reads, 1, "Reported once")
        XCTAssertEqual(pasteboard.changeCount, written, "Reads don't bump changeCount")
    }

    func testPasteWriteIsMarkedTransientForClipboardManagers() {
        pasteboard.writeForPaste("dictated") {}
        XCTAssertEqual(nsPasteboard.types?.contains(.init(ClipboardSnapshot.transientType)), true)
    }

    func testPasteProviderReleasedWhenReplaced() {
        pasteboard.writeForPaste("one") {}
        pasteboard.restore(.empty)
        XCTAssertFalse(pasteboard.isServingPasteText, "Our restore drops the provider")

        pasteboard.writeForPaste("two") {}
        pasteboard.write("copied")
        XCTAssertFalse(pasteboard.isServingPasteText, "Our plain write drops it")

        pasteboard.writeForPaste("three") {}
        nsPasteboard.clearContents()   // someone else takes the pasteboard
        nsPasteboard.setString("theirs", forType: .string)
        let released = expectation(description: "pasteboard finished with the provider")
        DispatchQueue.main.async { if !self.pasteboard.isServingPasteText { released.fulfill() } }
        wait(for: [released], timeout: 1)
    }

    // MARK: - Snapshot: promises and unreadable types

    func testSnapshotSkipsFilePromisesWithoutResolvingThem() {
        final class Provider: NSObject, NSPasteboardItemDataProvider {
            var asked: [NSPasteboard.PasteboardType] = []
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {
                asked.append(type)   // provides nothing: an unresolvable promise
            }
        }
        let provider = Provider()
        let promiseURL = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        let lazyPrivate = NSPasteboard.PasteboardType("com.example.voicetype.lazy")
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([0x01]), forType: .init("com.apple.NSFilePromiseItemMetaData"))
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [promiseURL, lazyPrivate]))
        XCTAssertTrue(nsPasteboard.writeObjects([item]))

        let types = pasteboard.snapshot().items.flatMap { $0.representations.map(\.type) }

        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertFalse(types.contains("com.apple.NSFilePromiseItemMetaData"))
        XCTAssertFalse(types.contains(promiseURL.rawValue))
        XCTAssertFalse(provider.asked.contains(promiseURL), "A file promise is never forced")
        XCTAssertFalse(types.contains(lazyPrivate.rawValue), "A type with no data is left out")
    }
}
