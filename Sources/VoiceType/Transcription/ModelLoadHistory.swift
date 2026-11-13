import Foundation

/// Which models have loaded on this Mac, and on which macOS build, so a
/// Core ML engine's first load can say so: Core ML specializes a model for
/// this chip's Neural Engine the first time it's loaded (seconds to a
/// minute), caches the result, and does it again after a macOS update. The
/// OS's cache can't be asked, so this remembers instead: a small JSON
/// sidecar (`Paths.modelLoadsFile`), keyed by engine and model folder, of
/// the OS build each last loaded on. A wrong guess only changes a status
/// line. Deleting it is harmless.
///
/// Thread-safe.
final class ModelLoadHistory: @unchecked Sendable {
    static let shared = ModelLoadHistory(url: Paths.modelLoadsFile)

    private let url: URL?
    private let osBuild: String
    private let lock = NSLock()
    private var loads: [String: String]?

    /// `url` nil keeps it in memory only. `osBuild` identifies this macOS
    /// install (default: the running one's version and build).
    init(url: URL?, osBuild: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.url = url
        self.osBuild = osBuild
    }

    /// Whether `spec`'s model has loaded on this OS build before.
    func hasLoaded(_ spec: ModelSpec) -> Bool {
        lock.withLock { loaded()[Self.key(spec)] == osBuild }
    }

    /// `spec`'s model just loaded: later loads on this OS build aren't first loads.
    func recordLoad(_ spec: ModelSpec) {
        lock.withLock {
            var updated = loaded()
            guard updated[Self.key(spec)] != osBuild else { return }
            updated[Self.key(spec)] = osBuild
            loads = updated
            guard let url else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            } catch {
                Log.error("Could not save the model load history: \(error.localizedDescription)")
            }
        }
    }

    /// The model, not the language: the compiled model doesn't depend on it.
    private static func key(_ spec: ModelSpec) -> String { "\(spec.engine.rawValue):\(spec.path)" }

    /// Under `lock`.
    private func loaded() -> [String: String] {
        if let loads { return loads }
        let read = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        loads = read
        return read
    }
}
