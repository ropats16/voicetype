import Foundation

/// Folder models (WhisperKit's and Parakeet's Core ML folders: many files,
/// not one; see `FolderModelCatalog`). The download writes a manifest into the
/// folder — `shasum -a 256` lines, one per file, sorted by path — and the
/// catalog pins the manifest's own SHA-256. So one pinned digest covers every
/// file: the manifest must hash to it, then each file it lists must hash to
/// its line. Files outside the manifest are ignored. Each file goes through
/// the same stamp cache as a single-file model, so an unchanged folder is
/// never re-hashed.
extension ModelVerifier {
    /// The manifest's name inside a folder model.
    static let folderManifestName = "voicetype-manifest.sha256"

    /// Throws `ModelChecksumMismatch` naming the manifest (not the pinned
    /// one) or the first file that doesn't match it; a file-read error if one
    /// is missing; `CocoaError(.fileReadCorruptFile)` for a malformed manifest
    /// (including a path leaving the folder). `willHash` runs at most once,
    /// before the first file that must actually be hashed.
    func verifyFolder(path folder: String, manifestSHA256 expected: String, willHash: () -> Void = {}) throws {
        var announced = false
        let announce = { if !announced { announced = true; willHash() } }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let manifestURL = root.appendingPathComponent(Self.folderManifestName)

        guard try cachedSHA256(of: manifestURL.path, willHash: announce).lowercased() == expected.lowercased() else {
            throw ModelChecksumMismatch(filename: Self.folderManifestName)
        }
        for entry in try Self.parseFolderManifest(String(contentsOf: manifestURL, encoding: .utf8), at: manifestURL) {
            let file = root.appendingPathComponent(entry.path).path
            guard try cachedSHA256(of: file, willHash: announce).lowercased() == entry.sha256 else {
                throw ModelChecksumMismatch(filename: entry.path)
            }
        }
    }

    /// `<sha256>  <relative path>` lines (blank lines skipped). Paths must stay
    /// inside the folder.
    static func parseFolderManifest(_ text: String, at url: URL) throws -> [(sha256: String, path: String)] {
        let malformed = CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        return try text.split(separator: "\n").compactMap { line in
            guard !line.allSatisfy(\.isWhitespace) else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { throw malformed }
            let sha = parts[0].lowercased()
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            let components = path.split(separator: "/")
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit), !path.isEmpty, !path.hasPrefix("/"),
                  !components.contains(where: { $0 == ".." || $0 == "." }) else { throw malformed }
            return (sha, path)
        }
    }
}
