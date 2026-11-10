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
}
