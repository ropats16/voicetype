import Foundation

/// One file of a folder model, pinned: where it comes from, where it goes
/// in the folder, and what it must be.
struct PinnedFile: Equatable, Sendable {
    /// `<repo>/resolve/<commit>/<path>` on Hugging Face.
    let source: String
    /// Relative to the model folder; what the manifest lists.
    let path: String
    let bytes: Int64
    /// Lowercase hex.
    let sha256: String
}

/// The folder models' per-file pins, for the in-app download. The tables are
/// `scripts/<engine>_files.tsv` (id, source, local path, bytes, sha256 per
/// row), the ones `make whisperkit-model` / `make parakeet-model` read,
/// embedded verbatim by `scripts/embed_folder_model_pins.sh` — one source of
/// truth, no resource bundle to package. `FolderModelPinsTests` checks the
/// copy is current and that each model's manifest hashes to its catalog pin.
enum FolderModelPins {
    /// A table's rows by model id, in table order (comments and blank lines skipped).
    static func parse(_ table: String) -> [String: [PinnedFile]] {
        var files: [String: [PinnedFile]] = [:]
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, let bytes = Int64(f[3]) else { continue }
            files[f[0], default: []].append(PinnedFile(source: f[1], path: f[2], bytes: bytes, sha256: f[4].lowercased()))
        }
        return files
    }

    /// The manifest a folder holding `files` gets (`voicetype-manifest.sha256`):
    /// `<sha256>  <path>` lines sorted bytewise by path, byte-identical to
    /// `scripts/lib/folder_model.sh`'s, so it hashes to the catalog's pin.
    static func manifest(_ files: [PinnedFile]) -> String {
        files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            .map { "\($0.sha256)  \($0.path)\n" }.joined()
    }

    static let whisperKit = parse(whisperKitTable)
    static let parakeet = parse(parakeetTable)
}

extension WhisperKitCatalog {
    /// Every file of model `id`; empty for an id not in the catalog.
    static func pinnedFiles(for id: String) -> [PinnedFile] { FolderModelPins.whisperKit[id] ?? [] }
}

extension ParakeetCatalog {
    /// Every file of model `id`; empty for an id not in the catalog.
    static func pinnedFiles(for id: String) -> [PinnedFile] { FolderModelPins.parakeet[id] ?? [] }
}
