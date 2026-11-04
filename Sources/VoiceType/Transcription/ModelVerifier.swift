import Foundation
import CryptoKit

/// A model file that isn't byte-for-byte the one the catalog pins.
struct ModelChecksumMismatch: LocalizedError, Equatable {
    let filename: String

    var errorDescription: String? {
        "\(filename) doesn't match its published checksum (corrupt or incomplete download). Delete it and download it again."
    }
}

/// Checks model files against their pinned SHA-256 before the engine loads
/// them.
///
/// Hashing a 1.5 GB model takes seconds, so results are cached in a small JSON
/// sidecar (`Paths.checksumCacheFile`) keyed by path, and reused while the
/// file's size, modification date, inode and status-change time (ctime) are
/// unchanged. The last two can't be preserved by a user or tool (`touch -r`
/// can fake an mtime, not a ctime), so a replaced or rewritten file is always
/// re-hashed. A sidecar rather than
/// UserDefaults because it sits beside `config.json`: the `.app` and a
/// `swift run` build (different defaults domains) share it, it honours
/// `VOICETYPE_APP_SUPPORT`, and deleting it just forces a re-hash. Bad results
/// are cached too, so a corrupt file isn't re-hashed on every launch; replacing
/// it re-checks it.
///
/// Thread-safe; the engine calls it on its own queue, never on main.
final class ModelVerifier: @unchecked Sendable {
    static let shared = ModelVerifier(cacheURL: Paths.checksumCacheFile)

    /// What identifies one version of a file on disk.
    private struct Stamp: Codable, Equatable {
        let size: Int64
        let modified: TimeInterval
        let changed: TimeInterval   // ctime
        let inode: UInt64

        init(path: String) throws {
            var st = stat()
            guard stat(path, &st) == 0 else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            }
            size = Int64(st.st_size)
            modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
            changed = TimeInterval(st.st_ctimespec.tv_sec) + TimeInterval(st.st_ctimespec.tv_nsec) / 1e9
            inode = UInt64(st.st_ino)
        }
    }

    private struct Entry: Codable, Equatable {
        let stamp: Stamp
        let sha256: String
    }

    private let cacheURL: URL?
    private let hash: (URL) throws -> String
    private let lock = NSLock()
    private var cache: [String: Entry]?

    /// `cacheURL` nil keeps the cache in memory only. `hash` is injectable so
    /// tests can count hashes.
    init(cacheURL: URL?, hash: @escaping (URL) throws -> String = { try ModelVerifier.sha256(of: $0) }) {
        self.cacheURL = cacheURL
        self.hash = hash
    }

    /// Throws `ModelChecksumMismatch` unless the file at `path` hashes to
    /// `expected` (or a file-read error if it can't be read). `willHash` runs
    /// first if the file must actually be hashed (not in the cache), so the
    /// caller can say so.
    func verify(path: String, sha256 expected: String, willHash: () -> Void = {}) throws {
        let url = URL(fileURLWithPath: path)
        let stamp = try Stamp(path: path)

        let actual: String
        if let cached = lock.withLock({ loadedCache()[path] }), cached.stamp == stamp {
            actual = cached.sha256
        } else {
            willHash()
            let start = Date()
            actual = try hash(url)
            Log.info("Checksummed \(url.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s.")
            lock.withLock { store(Entry(stamp: stamp, sha256: actual), for: path) }
        }
        guard actual.lowercased() == expected.lowercased() else {
            throw ModelChecksumMismatch(filename: url.lastPathComponent)
        }
    }

    /// Streams the file through SHA-256 in 4 MB chunks, so memory stays flat.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache (under `lock`)

    private func loadedCache() -> [String: Entry] {
        if let cache { return cache }
        let loaded = cacheURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    private func store(_ entry: Entry, for path: String) {
        var updated = loadedCache()
        updated[path] = entry
        cache = updated
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: cacheURL, options: .atomic)
        } catch {
            Log.error("Could not save the model checksum cache: \(error.localizedDescription)")
        }
    }
}
