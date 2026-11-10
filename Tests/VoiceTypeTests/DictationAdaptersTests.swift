import XCTest
@testable import VoiceType

/// The live adapters behind `DictationSession`'s ports, where they hold logic.
final class DictationAdaptersTests: XCTestCase {

    // MARK: - Delivery: focus verdict → paste or copy

    private func deliver(_ text: String, focus: CaretLocator.FocusVerdict)
        -> (outcome: DeliveryOutcome, pasted: [String], copied: [String]) {
        var pasted: [String] = [], copied: [String] = []
        let delivery = PasteDelivery(focusVerdict: { focus },
                                     paste: { pasted.append($0) },
                                     copy: { copied.append($0) })
        let outcome = delivery.deliver(text)
        return (outcome, pasted, copied)
    }

    func testEditableFieldIsPasted() {
        let r = deliver("hi", focus: .editable)
        XCTAssertEqual(r.outcome, .pasted)
        XCTAssertEqual(r.pasted, ["hi"])
        XCTAssertTrue(r.copied.isEmpty)
    }

    func testUnknownFocusIsPastedAnyway() {
        let r = deliver("hi", focus: .unknown)
        XCTAssertEqual(r.outcome, .pasted)
        XCTAssertEqual(r.pasted, ["hi"])
        XCTAssertTrue(r.copied.isEmpty)
    }

    func testNonEditableFocusIsCopied() {
        let r = deliver("hi", focus: .notEditable)
        XCTAssertEqual(r.outcome, .copied)
        XCTAssertTrue(r.pasted.isEmpty)
        XCTAssertEqual(r.copied, ["hi"])
    }

    // MARK: - Engine: text back on main

    private final class EchoAdapter: TranscriptionAdapter {
        func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
            [.init(text: " Hello", start: 0, end: 1), .init(text: " world.", start: 1, end: 2)]
        }
    }

    private func makeEngine(_ path: String) -> TranscriptionEngine {
        TranscriptionEngine(model: ModelSpec(path: path, sha256: nil, language: "en"),
                            makeAdapter: { _ in EchoAdapter() })
    }

    func testEngineAdapterReturnsRawTextOnMain() {
        let model = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adapter-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: model) }
        let engine = makeEngine(model.path)
        engine.load()   // the job waits for the load

        let done = expectation(description: "transcribed")
        EngineDictationAdapter(engine).transcribe([0.1]) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), " Hello world.")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testEngineAdapterReportsFailureOnMain() {
        let engine = makeEngine("/nonexistent/model.bin")
        let done = expectation(description: "failed")
        EngineDictationAdapter(engine).transcribe([0.1]) { result in   // never loaded
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("Expected modelNotLoaded") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
