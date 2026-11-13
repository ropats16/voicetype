import XCTest
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

    func testAModelFolderResolvesToItsCatalogEntry() throws {
        let tiny = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        let folder = WhisperKitCatalog.folder(for: tiny.id, in: URL(fileURLWithPath: "/tmp/vt/models"))
        XCTAssertEqual(folder.path, "/tmp/vt/models/whisperkit/tiny.en")
        XCTAssertEqual(WhisperKitCatalog.model(forFolder: folder.path), tiny)
        XCTAssertEqual(WhisperKitCatalog.model(forFolder: "/elsewhere/tiny.en/"), tiny)
        XCTAssertNil(WhisperKitCatalog.model(forFolder: "/elsewhere/my-finetune"))
        XCTAssertNil(WhisperKitCatalog.model(forFolder: ""))
    }

    // MARK: - Script parity

    func testScriptTableAddsUpToThePinnedManifests() throws {
        let table = try FolderModelTable("whisperkit_files.tsv")
        XCTAssertEqual(table.ids, WhisperKitCatalog.models.map(\.id), "same ids, same order")

        for model in WhisperKitCatalog.models {
            XCTAssertEqual(table.manifestSHA256(model.id), model.manifestSHA256, "\(model.id) manifest")
            XCTAssertEqual(table.bytes(model.id), model.bytes, "\(model.id) size")
            let files = table.files(model.id)
            XCTAssertTrue(files.contains { $0.path == "tokenizer.json" }, "\(model.id) ships its tokenizer")
            for file in files where file.source.hasPrefix(WhisperKitCatalog.repo + "/") {
                XCTAssertTrue(file.source.hasPrefix("\(WhisperKitCatalog.repo)/resolve/\(WhisperKitCatalog.revision)/"),
                              "\(file.source) is pinned to the catalog's revision")
            }
        }
    }

    /// `make whisperkit-model` with no model fetches what Automatic picks for
    /// English.
    func testScriptDefaultIsTheEnglishAutomaticPick() throws {
        XCTAssertEqual(try FolderModelTable.scriptDefault("download_whisperkit_model.sh"),
                       WhisperKitCatalog.defaultModel(language: "en", hardware: .current).id)
    }
}
