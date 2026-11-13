import Foundation

/// Which models have loaded on this Mac and OS build: what the first-load
/// check (`EngineRegistry.isFirstLoad`) reads and every successful load
/// writes. A port, so readiness and the engine registry don't depend on the
/// file (`ModelLoadHistory` is the live one).
protocol ModelLoadRecording: AnyObject, Sendable {
    /// Whether `spec`'s model has loaded on this OS build before.
    func hasLoaded(_ spec: ModelSpec) -> Bool
    /// `spec`'s model just loaded: later loads on this OS build aren't first loads.
    func recordLoad(_ spec: ModelSpec)
}

/// Which models have loaded on this Mac, and on which macOS build, so a
/// Core ML engine's first load can say so: Core ML specializes a model for
/// this chip's Neural Engine the first time it's loaded (seconds to a
/// minute), caches the result, and does it again after a macOS update. The
/// OS's cache can't be asked, so this remembers instead: a small JSON
/// sidecar (`Paths.modelLoadsFile`), keyed by engine and model folder, of
/// the OS build each last loaded on. A wrong guess only changes a status
/// line. Deleting it is harmless.
///
/// Thread-safe. `recordLoad` updates memory at once and writes the file on
/// a background queue (it's called on main, from the engine's status).
final class ModelLoadHistory: ModelLoadRecording, @unchecked Sendable {
    static let shared = ModelLoadHistory(url: Paths.modelLoadsFile)

    /// This macOS install's build (`kern.osversion`, e.g. "25B78"): a point
    /// update or a rapid security response changes it, unlike the
    /// marketing version, and each recompiles Core ML models.
    static let currentOSBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(cString: build)
    }()

    private let url: URL?
    private let osBuild: String
    private let lock = NSLock()
    private var loads: [String: String]?
    private let writes = DispatchQueue(label: "VoiceType.ModelLoadHistory", qos: .utility)

    /// `url` nil keeps it in memory only. `osBuild` identifies this macOS
    /// install (default: the running one's build).
    init(url: URL?, osBuild: String = ModelLoadHistory.currentOSBuild) {
        self.url = url
        self.osBuild = osBuild
    }

    func hasLoaded(_ spec: ModelSpec) -> Bool {
        lock.withLock { loaded()[Self.key(spec)] == osBuild }
    }

    func recordLoad(_ spec: ModelSpec) {
        lock.withLock {
            var updated = loaded()
            guard updated[Self.key(spec)] != osBuild else { return }
            updated[Self.key(spec)] = osBuild
            loads = updated
            guard let url else { return }
            // Queued under the lock, onto a serial queue: the last write holds the latest snapshot.
            writes.async {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try JSONEncoder().encode(updated).write(to: url, options: .atomic)
                } catch {
                    Log.error("Could not save the model load history: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Waits for pending writes: before a command-line run exits, and in tests.
    func flush() {
        writes.sync {}
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
