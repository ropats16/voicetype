import XCTest
import CryptoKit
@testable import VoiceType

/// The in-app folder-model download (`FolderModelDownloader`), over a fake
/// HTTP transport and a temp models folder: it assembles the model in
/// `<id>.part/`, resumes an interrupted file, checks each file's pin, and only
/// then writes the manifest and renames the folder into place — so the final
/// path never holds a partial model. No network.
final class FolderModelDownloaderTests: XCTestCase {

    /// Serves fixed bodies by URL, honouring the start offset; records each
    /// request. `cut` makes a request stop (throwing, as a dropped connection
    /// does) after that many bytes; `hang` makes it wait until cancelled.
    private final class FakeTransport: DownloadTransport, @unchecked Sendable {
        var bodies: [URL: Data] = [:]
        private var _requests: [(url: URL, offset: Int64)] = []
        var requests: [(url: URL, offset: Int64)] { lock.withLock { _requests } }
        var cut: [URL: Int] = [:]
        var hang: Set<URL> = []
        var short: Set<URL> = []
        private let lock = NSLock()

        func fetch(_ url: URL, from offset: Int64, appendingTo file: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            lock.withLock { _requests.append((url, offset)) }
            var body = Data(bodies[url, default: Data()].dropFirst(Int(offset)))
            if short.contains(url) { body = body.dropLast(1) }
            let dropAfter = lock.withLock { cut.removeValue(forKey: url) }
            if let dropAfter { body = body.prefix(dropAfter) }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: body)
            try handle.close()
            progress(offset + Int64(body.count))
            if dropAfter != nil { throw URLError(.networkConnectionLost) }
            if hang.contains(url) { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }
    }

    private let base = URL(string: "https://hf.test")!
    private var modelsDir: URL!
    private let transport = FakeTransport()

    private let encoder = Data(repeating: 7, count: 300)
    private let vocab = Data("{\"a\": 1}".utf8)

    override func setUpWithError() throws {
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-download-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        transport.bodies = [url("Encoder.mlmodelc/weights/weight.bin"): encoder, url("vocab.json"): vocab]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: modelsDir)
    }

    private func url(_ path: String) -> URL { base.appendingPathComponent("org/m/resolve/abc/\(path)") }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private var files: [PinnedFile] {
        [PinnedFile(source: "org/m/resolve/abc/vocab.json", path: "vocab.json", bytes: Int64(vocab.count), sha256: sha(vocab)),
         PinnedFile(source: "org/m/resolve/abc/Encoder.mlmodelc/weights/weight.bin", path: "Encoder.mlmodelc/weights/weight.bin",
                    bytes: Int64(encoder.count), sha256: sha(encoder))]
    }

    private var download: ModelDownload {
        ModelDownload(modelID: "m", files: files, destination: modelsDir.appendingPathComponent("eng/m", isDirectory: true))
    }

    private var partFolder: URL { modelsDir.appendingPathComponent("eng/m.part", isDirectory: true) }

    private func run(progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        try await FolderModelDownloader(transport: transport, baseURL: base).download(download, progress: progress)
    }

    private func assertInstalled(file: StaticString = #filePath, line: UInt = #line) throws {
        let folder = download.destination
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("vocab.json")), vocab, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")), encoder,
                       file: file, line: line)
        let manifest = try Data(contentsOf: folder.appendingPathComponent(ModelVerifier.folderManifestName))
        // What the catalog would pin, and what the engine checks before loading.
        XCTAssertNoThrow(try ModelVerifier(cacheURL: nil).verifyFolder(path: folder.path, manifestSHA256: sha(manifest)),
                         file: file, line: line)
        XCTAssertEqual(String(decoding: manifest, as: UTF8.self),
                       "\(sha(encoder))  Encoder.mlmodelc/weights/weight.bin\n\(sha(vocab))  vocab.json\n",
                       file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFolder.path), "no staging folder left", file: file, line: line)
    }

    private func assertNotInstalled(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.destination.path),
                       "nothing at the final path", file: file, line: line)
    }

    // MARK: -

    func testDownloadsEveryFileThenMovesTheFinishedFolderIntoPlace() async throws {
        try await run()

        try assertInstalled()
        XCTAssertEqual(transport.requests.map(\.offset), [0, 0])
    }

    func testProgressCountsBytesAcrossFilesUpToTheTotal() async throws {
        let reports = Reports()
        try await run { reports.add($0) }

        let total = Int64(vocab.count + encoder.count)
        XCTAssertEqual(download.totalBytes, total)
        XCTAssertEqual(reports.values.last, total)
        XCTAssertEqual(reports.values, reports.values.sorted(), "never goes backwards")
    }

    func testAnInterruptedDownloadResumesWhereItStopped() async throws {
        transport.cut[url("Encoder.mlmodelc/weights/weight.bin")] = 120

        do { try await run(); XCTFail("the dropped connection should fail the download") } catch {}
        assertNotInstalled()

        try await run()

        try assertInstalled()
        let resumed = transport.requests.dropFirst(2).map { "\($0.url.lastPathComponent)@\($0.offset)" }
        XCTAssertEqual(resumed, ["weight.bin@120"], "only the cut file, from where it stopped")
    }

    func testAFileThatDoesntMatchItsPinIsDiscardedAndNothingIsInstalled() async throws {
        transport.bodies[url("vocab.json")] = Data("{\"b\": 2}".utf8)   // same size, other bytes

        do {
            try await run()
            XCTFail("a tampered file must fail the download")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .checksumMismatch(path: "vocab.json"))
        }
        assertNotInstalled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFolder.appendingPathComponent("vocab.json").path),
                       "the bad file isn't kept to resume from")
    }

    func testAShortFileIsReportedIncomplete() async throws {
        transport.short = [url("vocab.json")]

        do {
            try await run()
            XCTFail("a short file must fail the download")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .incomplete(path: "vocab.json", bytes: Int64(vocab.count - 1), expected: Int64(vocab.count)))
        }
        assertNotInstalled()
    }

    func testCancellingStopsAndKeepsWhatArrivedForTheNextTry() async throws {
        transport.hang = [url("Encoder.mlmodelc/weights/weight.bin")]
        let task = Task { try await run() }
        while transport.requests.count < 2 { await Task.yield() }

        task.cancel()

        do { try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        assertNotInstalled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partFolder.appendingPathComponent("vocab.json").path))
    }

    /// A finished folder that lost its manifest (or a file) is repaired like
    /// the script does: good files are kept, only what's missing is fetched.
    func testAFolderMissingItsManifestIsRepairedKeepingGoodFiles() async throws {
        let folder = download.destination
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try vocab.write(to: folder.appendingPathComponent("vocab.json"))

        try await run()

        try assertInstalled()
        XCTAssertEqual(transport.requests.map(\.url.lastPathComponent), ["weight.bin"])
    }

    /// A broken finished folder and an earlier partial one both there: the
    /// finished folder's files move into the partial one at the same
    /// relative paths, even when the models folder is reached through a
    /// symlink (an enumerator hands back resolved paths).
    func testAFolderAndAPartialOneAreMergedAtTheirRelativePaths() async throws {
        let fm = FileManager.default
        let real = modelsDir.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = modelsDir.appendingPathComponent("linked", isDirectory: true)
        try fm.createSymbolicLink(at: linked, withDestinationURL: real)
        let download = ModelDownload(modelID: "m", files: files, destination: linked.appendingPathComponent("eng/m"))
        let folder = download.destination, part = download.partFolder
        let weight = "Encoder.mlmodelc/weights/weight.bin"
        try fm.createDirectory(at: folder.appendingPathComponent("Encoder.mlmodelc/weights"), withIntermediateDirectories: true)
        try encoder.write(to: folder.appendingPathComponent(weight))
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        try vocab.write(to: part.appendingPathComponent("vocab.json"))

        try await FolderModelDownloader(transport: transport, baseURL: base).download(download)

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(weight)), encoder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("vocab.json")), vocab)
        XCTAssertEqual(transport.requests.count, 0, "both files were already there")
        XCTAssertFalse(fm.fileExists(atPath: part.path))
    }

    /// A pin naming a path outside the model folder is refused before
    /// anything is written.
    func testAPinPathLeavingTheFolderIsRefused() async throws {
        for bad in ["../evil.bin", "/tmp/evil.bin", "a/../../evil.bin", ""] {
            let files = [PinnedFile(source: "org/m/resolve/abc/vocab.json", path: bad, bytes: Int64(vocab.count),
                                    sha256: sha(vocab))]
            let download = ModelDownload(modelID: "m", files: files, destination: download.destination)
            do {
                try await FolderModelDownloader(transport: transport, baseURL: base).download(download)
                XCTFail("\(bad) should be refused")
            } catch let error as ModelDownloadError {
                XCTAssertEqual(error, .unsafePath(bad))
            }
        }
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFolder.path))
    }

    /// The download just checked every file against its pin, so the engine's
    /// verify before the first load answers from the checksum cache.
    func testTheFirstLoadsVerifyDoesntHashTheFilesAgain() async throws {
        let hashes = Reports()
        let verifier = ModelVerifier(cacheURL: nil, hash: { hashes.add(1); return try ModelVerifier.sha256(of: $0) },
                                     log: { _ in })

        try await FolderModelDownloader(transport: transport, baseURL: base, verifier: verifier).download(download)
        let manifest = try Data(contentsOf: download.destination.appendingPathComponent(ModelVerifier.folderManifestName))
        try verifier.verifyFolder(path: download.destination.path, manifestSHA256: sha(manifest))

        XCTAssertEqual(hashes.values.count, 0, "nothing re-hashed")
    }

    func testAnInstalledFolderIsLeftAlone() async throws {
        try await run()
        try await run()

        XCTAssertEqual(transport.requests.count, 2, "nothing fetched the second time")
        try assertInstalled()
    }
}

/// Progress values, collected from any thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    var values: [Int64] { lock.withLock { _values } }
    func add(_ value: Int64) { lock.withLock { _values.append(value) } }
}
