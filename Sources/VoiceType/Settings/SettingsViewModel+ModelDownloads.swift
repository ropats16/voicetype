import Foundation

/// Fetches a folder model's pinned files (`FolderModelDownloader`). A port,
/// so Settings is testable without the network or the disk.
protocol ModelDownloading: Sendable {
    /// `progress` gets the bytes in place so far, out of `download.totalBytes`.
    /// Cancel by cancelling the calling task (`CancellationError`).
    func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws
}

extension FolderModelDownloader: ModelDownloading {}

/// One model of one engine, for the downloads Settings runs.
struct ModelDownloadKey: Hashable {
    let engine: EngineKind
    let id: String
}

/// A Settings download under way, or the last one that failed.
enum ModelDownloadState: Equatable {
    case downloading(fraction: Double)
    case failed(String)
}

/// One row of Settings' Download list.
struct DownloadableModel: Hashable, Identifiable {
    let key: ModelDownloadKey
    /// The model's label; another engine's download also names its engine.
    let label: String
    var id: ModelDownloadKey { key }
}

/// Settings' Download button for engines whose models the app fetches itself
/// (WhisperKit, Parakeet: `EngineDescriptor.inAppDownload`), mirroring Apple
/// Speech's: only on an explicit click, with progress, Cancel and the reason
/// a download failed. Each not-downloaded model gets its own button; a
/// finished one moves to the downloaded list, and if it's the model the
/// settings select, the model settings are re-applied so the engine (which
/// reported `.missing`) loads it. `make whisperkit-model` / `make
/// parakeet-model` fetch the same pinned files.
///
/// Downloads are keyed by engine and model, not by the selected engine: one
/// started before an engine switch keeps running and stays listed (named
/// with its engine), so it can still be followed and cancelled. Cancel
/// keeps `<id>.part/` to resume from; the row offers to discard it.
extension SettingsViewModel {

    /// The Download list: the selected engine's not-downloaded models (in
    /// catalog order), then any other engine's downloads still under way.
    /// Empty for engines without in-app downloads.
    var inAppDownloadableModels: [DownloadableModel] {
        let own = modelLists.notDownloaded
            .filter { descriptor.inAppDownload(of: $0.id, in: modelsDir) != nil }
            .map { DownloadableModel(key: ModelDownloadKey(engine: engine, id: $0.id), label: $0.label) }
        let others = modelDownloads.keys
            .filter { $0.engine != engine && isDownloadingModel($0) }
            .sorted { ($0.engine.rawValue, $0.id) < ($1.engine.rawValue, $1.id) }
            .map { key -> DownloadableModel in
                let label = engines.descriptor(for: key.engine)?.models.first { $0.id == key.id }?.label ?? key.id
                return DownloadableModel(key: key, label: "\(label) — \(key.engine.displayName)")
            }
        return own + others
    }

    /// Whether model `key` can be downloaded now: its engine downloads
    /// in-app, it isn't installed, and no download of it is under way.
    func canDownloadModel(_ key: ModelDownloadKey) -> Bool {
        guard !isDownloadingModel(key), let descriptor = engines.descriptor(for: key.engine),
              descriptor.inAppDownload(of: key.id, in: modelsDir) != nil else { return false }
        return !descriptor.isPresent(descriptor.resolve(.named(key.id), in: modelContext(for: key.engine)))
    }

    /// Starts downloading model `key` (if `canDownloadModel`); the returned
    /// task ends when it settles, nil when nothing started.
    @discardableResult
    func downloadModel(_ key: ModelDownloadKey) -> Task<Void, Never>? {
        guard canDownloadModel(key),
              let download = engines.descriptor(for: key.engine)?.inAppDownload(of: key.id, in: modelsDir) else { return nil }
        let throttle = ProgressThrottle(total: download.totalBytes)
        let downloader = modelDownloader
        modelDownloads[key] = .downloading(fraction: 0)
        let progressed: @MainActor (Double) -> Void = { [weak self] in self?.modelDownloadProgressed(key, to: $0) }
        let task = Task { [weak self] in
            do {
                try await downloader.download(download) { bytes in
                    guard let fraction = throttle.report(bytes) else { return }
                    Task { @MainActor in progressed(fraction) }
                }
                self?.modelDownloadFinished(key, at: download.destination)
            } catch where error is CancellationError || Task.isCancelled {
                self?.modelDownloads[key] = nil
            } catch {
                Log.error("Downloading \(key.id) failed: \(error.localizedDescription)")
                self?.modelDownloads[key] = .failed("Download failed: \(error.localizedDescription)")
            }
            self?.modelDownloadTasks[key] = nil
        }
        modelDownloadTasks[key] = task
        return task
    }

    /// Stops model `key`'s download; what arrived is kept, so the next one resumes.
    func cancelModelDownload(_ key: ModelDownloadKey) {
        modelDownloadTasks[key]?.cancel()
    }

    func isDownloadingModel(_ key: ModelDownloadKey) -> Bool {
        if case .downloading? = modelDownloads[key] { return true }
        return false
    }

    /// e.g. "Downloading… 42%"; nil when model `key` isn't downloading.
    func modelDownloadLabel(_ key: ModelDownloadKey) -> String? {
        guard case .downloading(let fraction)? = modelDownloads[key] else { return nil }
        return "Downloading… \(Int((fraction * 100).rounded(.down)))%"
    }

    /// Why model `key`'s last download failed; cleared by the next one.
    func modelDownloadError(_ key: ModelDownloadKey) -> String? {
        guard case .failed(let reason)? = modelDownloads[key] else { return nil }
        return reason
    }

    /// Whether a stopped download of model `key` left its `<id>.part/`
    /// folder (kept to resume from), so the row can offer to discard it.
    func hasPartialDownload(_ key: ModelDownloadKey) -> Bool {
        guard !isDownloadingModel(key), let part = partFolder(key) else { return false }
        return FileManager.default.fileExists(atPath: part.path)
    }

    /// Deletes model `key`'s partial download (not while it's downloading).
    func discardPartialDownload(_ key: ModelDownloadKey) {
        guard hasPartialDownload(key), let part = partFolder(key) else { return }
        do {
            try FileManager.default.removeItem(at: part)
        } catch {
            Log.error("Could not delete \(part.path): \(error.localizedDescription)")
        }
        objectWillChange.send()   // read from disk
    }

    /// Whether the engine's model `spec` (reported missing) has a Download
    /// button in the selected engine's list: its folder is where that
    /// engine's download of the model named like it goes.
    func isDownloadableInApp(_ spec: ModelSpec) -> Bool {
        guard spec.engine == engine else { return false }
        let folder = URL(fileURLWithPath: spec.path)
        guard let download = descriptor.inAppDownload(of: folder.lastPathComponent, in: modelsDir) else { return false }
        return download.destination.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    // MARK: - Private

    private func partFolder(_ key: ModelDownloadKey) -> URL? {
        engines.descriptor(for: key.engine)?.inAppDownload(of: key.id, in: modelsDir)?.partFolder
    }

    /// Progress hops here in tasks that may run out of order: never back.
    private func modelDownloadProgressed(_ key: ModelDownloadKey, to fraction: Double) {
        // A late report mustn't undo the finished state.
        guard case .downloading(let shown)? = modelDownloads[key], fraction > shown else { return }
        modelDownloads[key] = .downloading(fraction: fraction)
    }

    private func modelDownloadFinished(_ key: ModelDownloadKey, at folder: URL) {
        modelDownloads[key] = nil
        objectWillChange.send()   // the model lists are read from disk
        let selected = selection(configStore.config).spec   // under Automatic, a Turbo download is its new pick
        guard URL(fileURLWithPath: selected.path).standardizedFileURL == folder.standardizedFileURL else { return }
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }
}

/// Thins a download's progress reports (one per network chunk, thousands a
/// second) to what's worth a redraw: a fraction at least 1% past the last
/// one passed on, or 0.1 s after it, and never lower. Thread-safe: the
/// reports come from the transport's queue.
final class ProgressThrottle: @unchecked Sendable {
    private let total: Double
    private let minStep: Double
    private let minInterval: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var last: (fraction: Double, time: TimeInterval)?

    init(total: Int64, minStep: Double = 0.01, minInterval: TimeInterval = 0.1,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.total = Double(max(total, 1))
        self.minStep = minStep
        self.minInterval = minInterval
        self.clock = clock
    }

    /// The fraction to show for `bytes` so far, or nil to skip this report.
    func report(_ bytes: Int64) -> Double? {
        let fraction = min(Double(bytes) / total, 1)
        let now = clock()
        return lock.withLock {
            if let last {
                guard fraction > last.fraction,
                      fraction - last.fraction >= minStep || now - last.time >= minInterval || fraction == 1 else { return nil }
            }
            last = (fraction, now)
            return fraction
        }
    }
}
