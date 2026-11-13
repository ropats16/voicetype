import XCTest
import CryptoKit
@testable import VoiceType

/// A download script's pinned file table (`scripts/<engine>_files.tsv`: id,
/// source, local path, bytes, sha256 per file), for the catalog parity
/// tests: the per-file hashes the script checks must add up to the manifest
/// digest the app pins, so the script fetches exactly what the app verifies.
struct FolderModelTable {
    struct Row { let id, source, path: String; let bytes: Int64; let sha256: String }

    static let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts")

    let rows: [Row]

    init(_ name: String) throws {
        rows = try String(contentsOf: Self.scripts.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { line in
                let f = line.split(separator: "\t").map(String.init)
                XCTAssertEqual(f.count, 5, "malformed row: \(line)")
                return Row(id: f[0], source: f[1], path: f[2], bytes: Int64(f[3]) ?? -1, sha256: f[4])
            }
    }

    /// Model ids in table order.
    var ids: [String] {
        var ids: [String] = []
        for row in rows where !ids.contains(row.id) { ids.append(row.id) }
        return ids
    }

    /// `id`'s files, sorted by path bytewise (the manifest's order).
    func files(_ id: String) -> [Row] {
        rows.filter { $0.id == id }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// SHA-256 of the manifest the script writes for `id`.
    func manifestSHA256(_ id: String) -> String {
        let manifest = files(id).map { "\($0.sha256)  \($0.path)\n" }.joined()
        return SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func bytes(_ id: String) -> Int64 { files(id).map(\.bytes).reduce(0, +) }

    /// The default model in the download script `name` (`MODEL="${1:-<id>}"`).
    static func scriptDefault(_ name: String) throws -> String? {
        let source = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
        guard let range = source.range(of: #"MODEL="\$\{1:-([^}]+)\}""#, options: .regularExpression) else { return nil }
        return String(source[range].dropFirst(#"MODEL="${1:-"#.count).dropLast(2))
    }
}
