import XCTest
@testable import VoiceType

/// The download/setup scripts mirror the engine's catalog and auto-pick in
/// `scripts/model_catalog.sh`, so `make setup` downloads the model the app
/// will pick and checks the same pinned hashes. These keep the two in step.
final class ModelCatalogScriptParityTests: XCTestCase {

    private let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts")

    func testScriptTableMatchesTheCatalog() throws {
        let source = try String(contentsOf: scripts.appendingPathComponent("model_catalog.sh"), encoding: .utf8)
        let table = try XCTUnwrap(source.components(separatedBy: "# BEGIN MODELS").last?
            .components(separatedBy: "# END MODELS").first)
        let rows = table.split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
            .filter { $0.count == 3 }

        XCTAssertEqual(rows.map { $0[0] }, ModelCatalog.models.map(\.id), "same ids, same order")
        for (row, model) in zip(rows, ModelCatalog.models) {
            XCTAssertEqual(row[1], model.sha256, "\(model.id) sha256")
            XCTAssertEqual(Int64(row[2]), model.bytes, "\(model.id) size")
        }
    }

    func testDetectHardwarePicksWhatTheAppPicks() throws {
        for (arch, appleSilicon) in [("arm64", true), ("x86_64", false)] {
            for gib: UInt64 in [4, 7, 8, 12, 15, 16, 24, 31, 32, 64] {
                let script = try detectModel(arch: arch, memoryBytes: gib << 30)
                let app = ModelCatalog.recommended(for: HardwareProfile(isAppleSilicon: appleSilicon,
                                                                         memoryBytes: gib << 30)).id
                XCTAssertEqual(script, app, "\(arch) \(gib) GB")
            }
        }
    }

    private func detectModel(arch: String, memoryBytes: UInt64) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scripts.appendingPathComponent("detect_hardware.sh").path, "--model"]
        process.environment = ["DETECT_ARCH": arch, "DETECT_MEM_BYTES": String(memoryBytes),
                               "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
