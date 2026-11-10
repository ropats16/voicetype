import XCTest
@testable import VoiceType

/// The live adapters behind `DictationSession`'s ports, where they hold logic.
final class DictationAdaptersTests: XCTestCase {

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

/// `SystemClock` against the real main run loop.
final class SystemClockTests: XCTestCase {
    func testTimerFiresWhileAMenuIsTracking() {
        // An open menu (the menu-bar menu) runs main in `.eventTracking`. AppKit
        // makes that a common mode in the app; this process has no NSApplication,
        // so register it the same way.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        var fired = false
        _ = SystemClock().schedule(after: 0.01) { fired = true }
        let deadline = Date().addingTimeInterval(1)
        while !fired && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(fired)
    }

    func testCancelledTimerNeverFires() {
        var fired = false
        let timer = SystemClock().schedule(after: 0.01) { fired = true }
        timer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(fired)
    }
}
