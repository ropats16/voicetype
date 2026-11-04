import Foundation

/// The bench's fixture list: one clip per line, tab-separated
/// `kind<TAB>path<TAB>reference`, where kind is `short` (a dictation, timed for
/// latency) or `long` (timed for real-time factor), path is relative to the
/// manifest's directory (or absolute), and reference is the true transcript.
/// Blank lines and `#` comments are ignored. `scripts/fetch_bench_fixtures.sh`
/// writes one.
enum BenchManifest {
    struct Entry: Equatable {
        /// The file name without its extension.
        let id: String
        let kind: BenchClip.Kind
        let file: URL
        let reference: String
    }

    struct ParseError: LocalizedError {
        let line: Int
        let problem: String
        var errorDescription: String? { "manifest line \(line): \(problem)" }
    }

    static func load(_ url: URL) throws -> [Entry] {
        try parse(String(contentsOf: url, encoding: .utf8), relativeTo: url.deletingLastPathComponent())
    }

    static func parse(_ text: String, relativeTo dir: URL) throws -> [Entry] {
        var entries: [Entry] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3, !columns[1].isEmpty else {
                throw ParseError(line: i + 1, problem: "expected kind<TAB>path<TAB>reference")
            }
            guard let kind = BenchClip.Kind(rawValue: String(columns[0])) else {
                throw ParseError(line: i + 1, problem: "unknown kind '\(columns[0])' (use short or long)")
            }
            let path = String(columns[1])
            let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
            entries.append(Entry(id: file.deletingPathExtension().lastPathComponent, kind: kind,
                                 file: file.standardizedFileURL, reference: String(columns[2])))
        }
        return entries
    }
}
