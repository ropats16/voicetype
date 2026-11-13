import Foundation

/// Folder models (WhisperKit's and Parakeet's Core ML folders: many files,
/// not one; see `FolderModelCatalog`). The download writes a manifest into the
/// folder — `shasum -a 256` lines, one per file, sorted by path — and the
/// catalog pins the manifest's own SHA-256. So one pinned digest covers every
/// file: the manifest must hash to it, then each file it lists must hash to
/// its line. Files outside the manifest are ignored. Each file goes through
/// the same stamp cache as a single-file model, so an unchanged folder is
/// never re-hashed; a verify that hashed anything logs one summary line
/// ("Checksummed 22 files of parakeet-tdt-0.6b-v3 in 0.2s."), not one per file.
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
        func announce() { if !announced { announced = true; willHash() } }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let manifestURL = root.appendingPathComponent(Self.folderManifestName)

        // Summed over the files actually hashed; logged once, even on a throw.
        var hashed = 0
        var seconds: TimeInterval = 0
        defer {
            if hashed > 0 {
                log("Checksummed \(hashed) file\(hashed == 1 ? "" : "s") of \(root.lastPathComponent) "
                    + "in \(Self.seconds(seconds)).")
            }
        }
        func sha256(_ path: String) throws -> String {
            let result = try cachedSHA256Unlogged(of: path, willHash: announce)
            if let t = result.hashSeconds { hashed += 1; seconds += t }
            return result.sha256.lowercased()
        }

        guard try sha256(manifestURL.path) == expected.lowercased() else {
            throw ModelChecksumMismatch(filename: Self.folderManifestName)
        }
        for entry in try Self.parseFolderManifest(String(contentsOf: manifestURL, encoding: .utf8), at: manifestURL) {
            guard try sha256(root.appendingPathComponent(entry.path).path) == entry.sha256 else {
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
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit), isInsideFolder(path) else { throw malformed }
            return (sha, path)
        }
    }

    /// A relative path that stays inside its folder: not empty or absolute,
    /// no `..` or `.` component. The manifest's lines and the download's
    /// pins both have to be.
    static func isInsideFolder(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/")
            && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}
