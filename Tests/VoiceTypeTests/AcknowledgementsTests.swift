import XCTest
@testable import VoiceType

/// Every engine the app can run is credited, in `ACKNOWLEDGEMENTS.md` (the
/// source for the Acknowledgements screen) and in its descriptor.
final class AcknowledgementsTests: XCTestCase {

    private let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ACKNOWLEDGEMENTS.md")

    func testEveryRegisteredEngineHasASection() throws {
        let headings = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("## ") }.map { $0.dropFirst(3) }
        for descriptor in EngineRegistry.shared.descriptors {
            XCTAssertTrue(headings.contains(Substring(descriptor.kind.displayName)),
                          "ACKNOWLEDGEMENTS.md needs a \"## \(descriptor.kind.displayName)\" section")
            XCTAssertFalse(descriptor.acknowledgement.isEmpty, "\(descriptor.kind) needs an acknowledgement")
        }
    }
}
