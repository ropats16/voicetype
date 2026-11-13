import XCTest
@testable import VoiceType

/// The Parakeet model catalog: pinned files, where a model lives, folder
/// verification, and which languages it can transcribe. Pure, or on a temp dir.
final class ParakeetCatalogTests: XCTestCase {

    // MARK: - Languages

    /// Parakeet TDT 0.6B v3's 25 European languages, per NVIDIA's model card.
    func testV3SupportsItsTwentyFiveEuropeanLanguages() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(Set(v3.languages), ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
                                           "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es",
                                           "sv", "ru", "uk"])
        XCTAssertEqual(v3.languages.count, 25)
    }

    /// The registry's filter: shown for a supported language or auto-detect
    /// (v3 detects among its own languages), hidden otherwise.
    func testSupportsLanguageCodesAutoDetectAndNothingElse() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        for code in ["en", "de", "uk", "EN", "Pt", ModelSpec.autoDetect] {
            XCTAssertTrue(v3.supports(language: code), code)
            XCTAssertTrue(ParakeetCatalog.supports(language: code), code)
        }
        for code in ["ja", "zh", "ar", "hi", "", "english"] {
            XCTAssertFalse(v3.supports(language: code), code)
            XCTAssertFalse(ParakeetCatalog.supports(language: code), code)
        }
    }

    // MARK: - Catalog

    func testV3IsPinnedFileByFileToARevision() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(v3.repo, "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(v3.revision.count, 40, "a commit, not a branch")
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            XCTAssertTrue(v3.files.contains { $0.path == "\(component).mlmodelc/weights/weight.bin" }, component)
        }
        XCTAssertTrue(v3.files.contains { $0.path == "parakeet_vocab.json" })
        for file in v3.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.sha256.allSatisfy { "0123456789abcdef".contains($0) }, file.path)
            XCTAssertGreaterThan(file.bytes, 0, file.path)
        }
        XCTAssertEqual(Set(v3.files.map(\.path)).count, v3.files.count, "paths are unique")
        XCTAssertEqual(v3.bytes, 483_105_645, "du of a fresh download")
    }

    func testModelFolderLivesUnderModelsParakeet() throws {
        let v3 = try XCTUnwrap(ParakeetCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        let models = URL(fileURLWithPath: "/tmp/vt/models")
        XCTAssertEqual(v3.folder(in: models).path, "/tmp/vt/models/parakeet/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetCatalog.model(forFolder: "/x/parakeet/parakeet-tdt-0.6b-v3/")?.id, v3.id)
        XCTAssertNil(ParakeetCatalog.model(forFolder: "/x/my-own-parakeet"))
        XCTAssertNil(ParakeetCatalog.model(forFolder: ""))
    }

    // MARK: - Verify

    private func makeFolder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// SHA-256 of "hello" and "world" (shasum -a 256).
    private let model = ParakeetModel(
        id: "test", repo: "r", revision: String(repeating: "0", count: 40), languages: ["en"],
        files: [
            .init(path: "a.json", bytes: 5, sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"),
            .init(path: "B.mlmodelc/weights/weight.bin", bytes: 5,
                  sha256: "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"),
        ])

    func testVerifyAcceptsTheExactFiles() throws {
        let folder = try makeFolder(["a.json": "hello", "B.mlmodelc/weights/weight.bin": "world"])
        XCTAssertNoThrow(try model.verify(folder: folder, verifier: ModelVerifier(cacheURL: nil)))
    }

    func testVerifyRejectsAChangedFile() throws {
        let folder = try makeFolder(["a.json": "hello", "B.mlmodelc/weights/weight.bin": "w0rld"])
        XCTAssertThrowsError(try model.verify(folder: folder, verifier: ModelVerifier(cacheURL: nil))) { error in
            XCTAssertEqual(error as? ModelChecksumMismatch, ModelChecksumMismatch(filename: "B.mlmodelc/weights/weight.bin"))
        }
    }

    func testVerifyRejectsAMissingFileWithoutHashingTheRest() throws {
        let folder = try makeFolder(["B.mlmodelc/weights/weight.bin": "world"])
        var hashed = 0
        let verifier = ModelVerifier(cacheURL: nil) { hashed += 1; return try ModelVerifier.sha256(of: $0) }
        XCTAssertThrowsError(try model.verify(folder: folder, verifier: verifier)) { error in
            XCTAssertEqual(error as? ParakeetModelIncomplete, ParakeetModelIncomplete(model: "test", missing: "a.json"))
        }
        XCTAssertEqual(hashed, 0, "a cheap presence check runs before any hashing")
    }
}
