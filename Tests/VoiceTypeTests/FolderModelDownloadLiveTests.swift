import XCTest
@testable import VoiceType

/// The real in-app download, over the network: WhisperKit tiny.en (79 MB)
/// from Hugging Face into a temp models folder, cancelled partway and
/// resumed, then verified against the catalog's pin as the engine does.
/// Opt-in: `VOICETYPE_LIVE_DOWNLOAD=1 swift test --filter FolderModelDownloadLiveTests`.
final class FolderModelDownloadLiveTests: XCTestCase {

    func testTinyEnDownloadsResumesAndVerifies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICETYPE_LIVE_DOWNLOAD"] == "1",
                          "set VOICETYPE_LIVE_DOWNLOAD=1 to download tiny.en from Hugging Face")
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: modelsDir) }
        let model = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        let download = try XCTUnwrap(WhisperKitEngine().inAppDownload(of: model.id, in: modelsDir))

        // Cancel once some MB are in, mid-file.
        let received = Received()
        let first = Task { try await FolderModelDownloader.live.download(download) { received.set($0) } }
        while received.bytes < 20 << 20 { try await Task.sleep(nanoseconds: 50_000_000) }
        first.cancel()
        do { try await first.value; XCTFail("should have been cancelled") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.destination.path))

        try await FolderModelDownloader.live.download(download)

        let spec = WhisperKitEngine().resolve(.named(model.id), in: ModelContext(
            language: "en", hardware: .current, modelsDir: modelsDir, presentFilenames: []))
        XCTAssertTrue(WhisperKitEngine().isPresent(spec))
        XCTAssertNoThrow(try ModelVerifier(cacheURL: nil).verify(path: spec.path, sha256: try XCTUnwrap(spec.sha256)))
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    var bytes: Int64 { lock.withLock { _bytes } }
    func set(_ value: Int64) { lock.withLock { _bytes = value } }
}
