import XCTest
@testable import VoiceType

/// The Parakeet model catalog, and its parity with the download script's
/// pinned file table (`scripts/parakeet_files.tsv`): the per-file hashes the
/// script checks must add up to the manifest digest the app pins.
final class ParakeetCatalogTests: XCTestCase {

    /// Parakeet TDT 0.6B v3's 25 European languages, per NVIDIA's model card.
    func testV3SupportsItsTwentyFiveEuropeanLanguages() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(Set(v3.languages), ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
                                           "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es",
                                           "sv", "ru", "uk"])
        XCTAssertEqual(v3.languages.count, 25)
    }

    func testV3IsPinnedToARevision() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(v3.repo, "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(v3.revision.count, 40, "a commit, not a branch")
        XCTAssertEqual(v3.bytes, 483_105_645, "du of a fresh download")
    }

    func testModelFolderLivesUnderModelsParakeet() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        let folder = ParakeetCatalog.folder(for: v3.id, in: URL(fileURLWithPath: "/tmp/vt/models"))
        XCTAssertEqual(folder.path, "/tmp/vt/models/parakeet/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetCatalog.model(forFolder: "/x/parakeet/parakeet-tdt-0.6b-v3/")?.id, v3.id)
        XCTAssertNil(ParakeetCatalog.model(forFolder: "/x/my-own-parakeet"))
        XCTAssertNil(ParakeetCatalog.model(forFolder: ""))
    }

    // MARK: - Script parity

    func testScriptTableAddsUpToThePinnedManifests() throws {
        let table = try FolderModelTable("parakeet_files.tsv")
        XCTAssertEqual(table.ids, ParakeetCatalog.models.map(\.id), "same ids, same order")

        for model in ParakeetCatalog.models {
            XCTAssertEqual(table.manifestSHA256(model.id), model.manifestSHA256, "\(model.id) manifest")
            XCTAssertEqual(table.bytes(model.id), model.bytes, "\(model.id) size")
            let files = table.files(model.id)
            for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
                XCTAssertTrue(files.contains { $0.path == "\(component).mlmodelc/weights/weight.bin" }, component)
            }
            XCTAssertTrue(files.contains { $0.path == "parakeet_vocab.json" })
            for file in files {
                XCTAssertEqual(file.source, "\(model.repo)/resolve/\(model.revision)/\(file.path)",
                               "\(file.path) comes from the pinned revision")
            }
        }
    }

    func testScriptDefaultIsTheAppsDefault() throws {
        XCTAssertEqual(try FolderModelTable.scriptDefault("download_parakeet_model.sh"),
                       ParakeetCatalog.defaultModel.id)
    }
}
