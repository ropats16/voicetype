import Foundation

/// One folder model to fetch: its pinned files and where the finished
/// folder goes (`EngineDescriptor.inAppDownload`).
struct ModelDownload: Equatable, Sendable {
    let modelID: String
    let files: [PinnedFile]
    /// The finished folder, `<models>/<subdirectory>/<id>/`.
    let destination: URL

    var totalBytes: Int64 { files.map(\.bytes).reduce(0, +) }

    /// Where the folder is assembled, beside the destination (same volume,
    /// so the final rename is atomic): `<id>.part/`, as the scripts use.
    var partFolder: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part", isDirectory: true)
    }
}

/// Why a download stopped. A dropped connection surfaces as the transport's
/// own error, a cancel as `CancellationError`.
enum ModelDownloadError: LocalizedError, Equatable {
    case http(status: Int)
    case incomplete(path: String, bytes: Int64, expected: Int64)
    case checksumMismatch(path: String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .http(let status):
            return "The server answered HTTP \(status)."
        case .incomplete(let path, let bytes, let expected):
            return "\(path) is incomplete (\(bytes) of \(expected) bytes). Check your connection and try again to resume."
        case .checksumMismatch(let path):
            return "\(path) doesn't match its pinned checksum (discarded). Try again."
        case .unsafePath(let path):
            return "The pinned path \"\(path)\" leaves the model folder."
        }
    }
}

/// One HTTP GET, the downloader's only way out to the network. A port, so
/// the downloader is tested without one (`URLSessionDownloadTransport` is
/// the live one).
protocol DownloadTransport: Sendable {
    /// Appends `url`'s body from byte `offset` on to `file` (created if
    /// missing), reporting how many bytes `file` holds as they arrive. A
    /// server that ignores the range restarts the file from zero. Throws on
    /// an HTTP error or a dropped connection, `CancellationError` when the
    /// task is cancelled; whatever arrived stays in `file`.
    func fetch(_ url: URL, from offset: Int64, appendingTo file: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Downloads a folder model the way `scripts/lib/folder_model.sh` does, so
/// Settings and `make whisperkit-model` / `make parakeet-model` produce the
/// same folder:
///
/// - The folder is assembled in `<id>.part/`; each file resumes from what's
///   there (HTTP Range) and must match its pinned size and SHA-256 (a bad
///   file is deleted, not kept to resume from).
/// - The manifest the catalog pins (`FolderModelPins.manifest`) is written
///   last, then the folder renamed into place. The app treats a catalog
///   folder as installed once its manifest is there, so it never sees a
///   partial model, and the engine still verifies every file before loading.
/// - A finished folder missing its manifest or a file is repaired, keeping
///   every good file.
///
/// Cancel by cancelling the calling task: it stops at once and keeps what
/// arrived for the next try.
struct FolderModelDownloader: Sendable {
    let transport: DownloadTransport
    /// What each `PinnedFile.source` is relative to.
    var baseURL = URL(string: "https://huggingface.co")!

    static let live = FolderModelDownloader(transport: URLSessionDownloadTransport())

    /// `progress` gets the bytes in place so far, out of `download.totalBytes`.
    func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let destination = download.destination, part = download.partFolder
        let manifest = FolderModelPins.manifest(download.files)
        // The pins are embedded, but a path leaving the folder would write anywhere.
        if let unsafe = download.files.first(where: { !ModelVerifier.isInsideFolder($0.path) }) {
            throw ModelDownloadError.unsafePath(unsafe.path)
        }

        if fm.fileExists(atPath: destination.path) {
            if Self.isComplete(destination, files: download.files, manifest: manifest) {
                return progress(download.totalBytes)
            }
            try Self.merge(destination, into: part)
        }
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        try? fm.removeItem(at: part.appendingPathComponent(ModelVerifier.folderManifestName))   // written last

        var done: Int64 = 0
        for file in download.files {
            try Task.checkCancellation()
            let out = part.appendingPathComponent(file.path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            var size = Self.size(of: out)
            if size == file.bytes, try ModelVerifier.sha256(of: out) == file.sha256 {
                done += file.bytes
                progress(done)
                continue
            }
            // At or past its size yet wrong: not a prefix to resume from.
            if size >= file.bytes { try fm.removeItem(at: out); size = 0 }

            let before = done
            try await transport.fetch(baseURL.appendingPathComponent(file.source), from: size, appendingTo: out) {
                progress(before + min($0, file.bytes))
            }
            size = Self.size(of: out)
            guard size == file.bytes else {
                throw ModelDownloadError.incomplete(path: file.path, bytes: size, expected: file.bytes)
            }
            guard try ModelVerifier.sha256(of: out) == file.sha256 else {
                try? fm.removeItem(at: out)
                throw ModelDownloadError.checksumMismatch(path: file.path)
            }
            done += file.bytes
        }

        try Data(manifest.utf8).write(to: part.appendingPathComponent(ModelVerifier.folderManifestName), options: .atomic)
        try fm.moveItem(at: part, to: destination)
        Log.info("Downloaded \(download.modelID) to \(destination.path).")
    }

    /// The pinned manifest is there and every file has its size (the engine
    /// hashes them before loading).
    private static func isComplete(_ folder: URL, files: [PinnedFile], manifest: String) -> Bool {
        let manifestURL = folder.appendingPathComponent(ModelVerifier.folderManifestName)
        return (try? String(contentsOf: manifestURL, encoding: .utf8)) == manifest
            && files.allSatisfy { size(of: folder.appendingPathComponent($0.path)) == $0.bytes }
    }

    /// Moves a finished folder's files over the partial one's (they were
    /// complete once; each is re-checked anyway), then drops the folder.
    /// The enumerator gives paths relative to the folder, not URLs: those
    /// come back symlink-resolved (/var → /private/var, a linked models
    /// folder), so cutting the folder's own path off them goes wrong.
    private static func merge(_ folder: URL, into part: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: part.path) else { return try fm.moveItem(at: folder, to: part) }
        // Listed first: moving files out while enumerating could skip some.
        let relatives = (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
        for relative in relatives {
            let file = folder.appendingPathComponent(relative)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let target = part.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: file, to: target)
        }
        try fm.removeItem(at: folder)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
