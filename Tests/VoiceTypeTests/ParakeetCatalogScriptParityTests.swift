import XCTest
@testable import VoiceType

/// `scripts/download_parakeet_model.sh` reads its pins from
/// `scripts/parakeet_catalog.sh`, which mirrors `ParakeetCatalog`, so the
/// script fetches exactly the files the app verifies. These keep the two in step.
final class ParakeetCatalogScriptParityTests: XCTestCase {

    private let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/parakeet_catalog.sh")

    /// The whitespace-split rows between `# BEGIN <name>` and `# END <name>`.
    private func table(_ name: String) throws -> [[String]] {
        let source = try String(contentsOf: script, encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "# BEGIN \(name)").last?
            .components(separatedBy: "# END \(name)").first)
        return body.split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
            .filter { $0.count >= 3 }
    }

    func testScriptModelsMatchTheCatalog() throws {
        let rows = try table("PARAKEET MODELS")
        XCTAssertEqual(rows.map { $0[0] }, ParakeetCatalog.models.map(\.id), "same ids, same order")
        for (row, model) in zip(rows, ParakeetCatalog.models) {
            XCTAssertEqual(row[1], model.repo, "\(model.id) repo")
            XCTAssertEqual(row[2], model.revision, "\(model.id) revision")
        }
    }

    func testScriptFilesMatchTheCatalog() throws {
        let rows = try table("PARAKEET FILES")
        let catalog = ParakeetCatalog.models.flatMap { model in model.files.map { (model.id, $0) } }
        XCTAssertEqual(rows.count, catalog.count, "same number of files")
        for (row, (id, file)) in zip(rows, catalog) {
            XCTAssertEqual(row[0], id)
            XCTAssertEqual(row[1], file.path, "\(id) path")
            XCTAssertEqual(row[2], file.sha256, "\(id) \(file.path) sha256")
            XCTAssertEqual(Int64(row[3]), file.bytes, "\(id) \(file.path) size")
        }
    }

    func testScriptDefaultIsTheAppsDefault() throws {
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(source.contains("PARAKEET_DEFAULT_MODEL=\"\(ParakeetCatalog.defaultModel.id)\""))
    }
}
