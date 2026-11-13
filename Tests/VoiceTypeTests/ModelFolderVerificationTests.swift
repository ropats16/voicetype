import XCTest
import CryptoKit
@testable import VoiceType

/// A folder model (WhisperKit's Core ML folders) is checked like a file: its
/// manifest (`shasum -a 256` lines) must hash to the pinned digest, and every
/// file it lists must match — with the same don't-re-hash cache.
final class ModelFolderVerificationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `files` into a model folder plus its manifest; returns the
    /// folder and the manifest's digest (what a catalog would pin).
    private func modelFolder(_ files: [String: String], manifest: String? = nil) throws -> (path: String, digest: String) {
        let folder = dir.appendingPathComponent("tiny.en")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let text = manifest ?? files.keys.sorted().map { "\(sha256(files[$0]!))  \($0)\n" }.joined()
        try Data(text.utf8).write(to: folder.appendingPathComponent(ModelVerifier.folderManifestName))
        return (folder.path, sha256(text))
    }

    private let files = ["AudioEncoder.mlmodelc/weights/weight.bin": "encoder", "tokenizer.json": "{}"]

    func testAnIntactFolderVerifies() throws {
        let model = try modelFolder(files)
        XCTAssertNoThrow(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: model.digest))
    }

    func testAManifestOtherThanThePinnedOneFails() throws {
        let model = try modelFolder(files)
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: sha256("other"))) {
            XCTAssertEqual($0 as? ModelChecksumMismatch,
                           ModelChecksumMismatch(filename: ModelVerifier.folderManifestName))
        }
    }

    func testATamperedFileFailsNamingIt() throws {
        let model = try modelFolder(files)
        try Data("evil".utf8).write(to: URL(fileURLWithPath: model.path).appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: model.digest)) {
            XCTAssertEqual($0 as? ModelChecksumMismatch, ModelChecksumMismatch(filename: "tokenizer.json"))
        }
    }

    func testAMissingFileOrManifestFails() throws {
        let model = try modelFolder(files)
        try FileManager.default.removeItem(atPath: model.path + "/AudioEncoder.mlmodelc/weights/weight.bin")
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: model.digest))

        try FileManager.default.removeItem(atPath: model.path + "/" + ModelVerifier.folderManifestName)
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: model.digest))
    }

    func testAManifestCannotReachOutsideTheFolder() throws {
        try Data("secret".utf8).write(to: dir.appendingPathComponent("outside"))
        let model = try modelFolder([:], manifest: "\(sha256("secret"))  ../outside\n")
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil).verify(path: model.path, sha256: model.digest))
    }

    func testAVerifiedFolderIsNotRehashedUntilAFileChanges() throws {
        let model = try modelFolder(files)
        var hashes = 0
        var announced = 0
        let verifier = ModelVerifier(cacheURL: nil) { hashes += 1; return try ModelVerifier.sha256(of: $0) }

        try verifier.verify(path: model.path, sha256: model.digest) { announced += 1 }
        XCTAssertEqual(hashes, 3, "manifest + two files")
        XCTAssertEqual(announced, 1, "willHash runs once per verify, before the first hash")

        try verifier.verify(path: model.path, sha256: model.digest) { announced += 1 }
        XCTAssertEqual(hashes, 3)
        XCTAssertEqual(announced, 1, "nothing to hash, so nothing announced")
    }

    // MARK: - Logging

    /// The verifier's log lines, with timings masked ("in 0.0s" → "in Ns").
    private final class LogLines {
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line.replacingOccurrences(of: #"in [0-9.]+s"#, with: "in Ns", options: .regularExpression))
        }
    }

    func testAFolderVerifyLogsOneSummaryLine() throws {
        let model = try modelFolder(files)
        let log = LogLines()
        let verifier = ModelVerifier(cacheURL: nil, log: log.log)

        try verifier.verify(path: model.path, sha256: model.digest)
        XCTAssertEqual(log.lines, ["Checksummed 3 files of tiny.en in Ns."])
    }

    func testAFolderVerifyLogsOnlyWhatItHashed() throws {
        let model = try modelFolder(files)
        let log = LogLines()
        let verifier = ModelVerifier(cacheURL: nil, log: log.log)
        try verifier.verify(path: model.path, sha256: model.digest)
        log.lines = []

        try verifier.verify(path: model.path, sha256: model.digest)
        XCTAssertEqual(log.lines, [], "all cached: nothing hashed, nothing logged")

        let tokenizer = URL(fileURLWithPath: model.path).appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: tokenizer)   // same bytes, new file version
        try verifier.verify(path: model.path, sha256: model.digest)
        XCTAssertEqual(log.lines, ["Checksummed 1 file of tiny.en in Ns."])
    }

    func testAFailedFolderVerifyStillLogsWhatItHashed() throws {
        let model = try modelFolder(files)
        try Data("evil".utf8).write(to: URL(fileURLWithPath: model.path).appendingPathComponent("tokenizer.json"))
        let log = LogLines()
        XCTAssertThrowsError(try ModelVerifier(cacheURL: nil, log: log.log).verify(path: model.path, sha256: model.digest))
        XCTAssertEqual(log.lines, ["Checksummed 3 files of tiny.en in Ns."])
    }

    func testASingleFileVerifyStillLogsTheFile() throws {
        let file = dir.appendingPathComponent("ggml-tiny.en.bin")
        try Data("weights".utf8).write(to: file)
        let log = LogLines()
        try ModelVerifier(cacheURL: nil, log: log.log).verify(path: file.path, sha256: sha256("weights"))
        XCTAssertEqual(log.lines, ["Checksummed ggml-tiny.en.bin in Ns."])
    }
}
