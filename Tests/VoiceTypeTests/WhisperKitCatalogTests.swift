import XCTest
import CryptoKit
@testable import VoiceType

/// The WhisperKit model catalog, and its parity with the download script's
/// pinned file table (`scripts/whisperkit_files.tsv`): the per-file hashes
/// the script checks must add up to the manifest digest the app pins.
final class WhisperKitCatalogTests: XCTestCase {

    func testCatalogHasEnglishMultilingualAndCompressedModels() {
        let ids = WhisperKitCatalog.models.map(\.id)
        for id in ["tiny.en", "base.en", "small.en", "tiny", "small", "small.en_217MB", "large-v3-v20240930_626MB"] {
            XCTAssertTrue(ids.contains(id), "catalog is missing \(id)")
        }
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
    }

    func testEnglishOnlyFollowsTheId() throws {
        XCTAssertTrue(try XCTUnwrap(WhisperKitCatalog.model(id: "small.en_217MB")).isEnglishOnly)
        XCTAssertTrue(try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en")).isEnglishOnly)
        XCTAssertFalse(try XCTUnwrap(WhisperKitCatalog.model(id: "large-v3-v20240930_626MB")).isEnglishOnly)
    }

    func testAModelFolderResolvesToItsCatalogEntryAndSpec() throws {
        let tiny = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        let folder = WhisperKitCatalog.folder(for: tiny)
        XCTAssertEqual(folder.lastPathComponent, "tiny.en")
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "whisperkit")
        XCTAssertEqual(WhisperKitCatalog.model(forFolder: folder.path), tiny)
        XCTAssertEqual(WhisperKitCatalog.model(forFolder: "/elsewhere/tiny.en/"), tiny)
        XCTAssertNil(WhisperKitCatalog.model(forFolder: "/elsewhere/my-finetune"))

        XCTAssertEqual(WhisperKitCatalog.spec(for: tiny, language: "en"),
                       ModelSpec(path: folder.path, sha256: tiny.manifestSHA256, language: "en", engine: .whisperKit))
    }

    // MARK: - Script parity

    private let table = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/whisperkit_files.tsv")

    private struct Row { let id, source, path: String; let bytes: Int64; let sha256: String }

    private func rows() throws -> [Row] {
        try String(contentsOf: table, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { line in
                let f = line.split(separator: "\t").map(String.init)
                XCTAssertEqual(f.count, 5, "malformed row: \(line)")
                return Row(id: f[0], source: f[1], path: f[2], bytes: Int64(f[3]) ?? -1, sha256: f[4])
            }
    }

    func testScriptTableAddsUpToThePinnedManifests() throws {
        let rows = try rows()
        var ids: [String] = []
        for row in rows where !ids.contains(row.id) { ids.append(row.id) }
        XCTAssertEqual(ids, WhisperKitCatalog.models.map(\.id), "same ids, same order")

        for model in WhisperKitCatalog.models {
            let files = rows.filter { $0.id == model.id }
                .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            let manifest = files.map { "\($0.sha256)  \($0.path)\n" }.joined()
            let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, model.manifestSHA256, "\(model.id) manifest")
            XCTAssertEqual(files.map(\.bytes).reduce(0, +), model.bytes, "\(model.id) size")
            XCTAssertTrue(files.contains { $0.path == "tokenizer.json" }, "\(model.id) ships its tokenizer")
            for file in files where file.source.hasPrefix(WhisperKitCatalog.repo + "/") {
                XCTAssertTrue(file.source.hasPrefix("\(WhisperKitCatalog.repo)/resolve/\(WhisperKitCatalog.revision)/"),
                              "\(file.source) is pinned to the catalog's revision")
            }
        }
    }
}
