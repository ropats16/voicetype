import XCTest
@testable import VoiceType

/// Tests for the pure ModelCatalog helpers.
/// No filesystem access — presence is injected via `presentFilenames`.
final class ModelCatalogTests: XCTestCase {

    // MARK: - filename(for:)

    func testFilenameForSize() {
        XCTAssertEqual(ModelCatalog.filename(for: "small.en"), "ggml-small.en.bin")
        XCTAssertEqual(ModelCatalog.filename(for: "medium.en"), "ggml-medium.en.bin")
        XCTAssertEqual(ModelCatalog.filename(for: "tiny.en"), "ggml-tiny.en.bin")
    }

    // MARK: - entries(presentFilenames:)

    func testEntriesAreOrderedTinyToMedium() {
        let entries = ModelCatalog.entries(presentFilenames: [])
        XCTAssertEqual(entries.map { $0.size }, ModelCatalog.sizes,
                       "entries must be in the same order as ModelCatalog.sizes")
    }

    func testEntriesMarkDownloadedCorrectly() {
        let present: Set<String> = ["ggml-small.en.bin", "ggml-medium.en.bin"]
        let entries = ModelCatalog.entries(presentFilenames: present)
        for entry in entries {
            let expected = present.contains(entry.filename)
            XCTAssertEqual(entry.isDownloaded, expected,
                           "\(entry.size) downloaded flag mismatch")
        }
    }

    func testEntriesNoneDownloadedWhenSetEmpty() {
        let entries = ModelCatalog.entries(presentFilenames: [])
        XCTAssertTrue(entries.allSatisfy { !$0.isDownloaded },
                      "no entries should be downloaded when presentFilenames is empty")
    }

    func testEntriesFilenameMatchesFilenameHelper() {
        let entries = ModelCatalog.entries(presentFilenames: [])
        for entry in entries {
            XCTAssertEqual(entry.filename, ModelCatalog.filename(for: entry.size))
        }
    }

    // MARK: - selectedSize(modelPath:)

    func testSelectedSizeForKnownPath() {
        let path = "/Library/Application Support/VoiceType/models/ggml-small.en.bin"
        XCTAssertEqual(ModelCatalog.selectedSize(modelPath: path), "small.en")
    }

    func testSelectedSizeForMediumPath() {
        let path = "/some/dir/ggml-medium.en.bin"
        XCTAssertEqual(ModelCatalog.selectedSize(modelPath: path), "medium.en")
    }

    func testSelectedSizeForUnknownPath() {
        let path = "/some/dir/ggml-custom.bin"
        XCTAssertNil(ModelCatalog.selectedSize(modelPath: path),
                     "unknown filename must return nil")
    }

    func testSelectedSizeForEmptyPath() {
        XCTAssertNil(ModelCatalog.selectedSize(modelPath: ""),
                     "empty path must return nil")
    }
}
