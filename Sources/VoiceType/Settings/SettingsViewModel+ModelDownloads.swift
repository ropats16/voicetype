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

/// Settings' Download button for engines whose models the app fetches itself
/// (WhisperKit, Parakeet: `EngineDescriptor.inAppDownload`), mirroring Apple
/// Speech's: only on an explicit click, with progress, Cancel and the reason
/// a download failed. Each not-downloaded model gets its own button; a
/// finished one moves to the downloaded list, and if it's the model the
/// settings select, the model settings are re-applied so the engine (which
/// reported `.missing`) loads it. `make whisperkit-model` / `make
/// parakeet-model` fetch the same pinned files.
extension SettingsViewModel {

    /// The selected engine's not-downloaded models that get a Download
    /// button (in catalog order); empty for engines without in-app downloads.
    var inAppDownloadableModels: [EngineModelOption] {
        modelLists.notDownloaded.filter { descriptor.inAppDownload(of: $0.id, in: Paths.modelsDir) != nil }
    }

    /// Whether model `id` of the selected engine can be downloaded now: the
    /// engine downloads in-app, it isn't installed, and no download of it is
    /// under way.
    func canDownloadModel(_ id: String) -> Bool {
        guard !isDownloadingModel(id), descriptor.inAppDownload(of: id, in: Paths.modelsDir) != nil else { return false }
        return !descriptor.isPresent(descriptor.resolve(.named(id), in: modelContext))
    }

    /// Starts downloading model `id` of the selected engine (if
    /// `canDownloadModel`); the returned task ends when it settles, nil when
    /// nothing started.
    @discardableResult
    func downloadModel(_ id: String) -> Task<Void, Never>? {
        guard canDownloadModel(id), let download = descriptor.inAppDownload(of: id, in: Paths.modelsDir) else { return nil }
        let key = ModelDownloadKey(engine: engine, id: id)
        let total = Double(max(download.totalBytes, 1))
        let downloader = modelDownloader
        modelDownloads[key] = .downloading(fraction: 0)
        let task = Task { [weak self] in
            do {
                try await downloader.download(download) { bytes in
                    Task { @MainActor [weak self] in
                        // A late report mustn't undo the finished state.
                        guard let self, case .downloading = self.modelDownloads[key] else { return }
                        self.modelDownloads[key] = .downloading(fraction: Double(bytes) / total)
                    }
                }
                self?.modelDownloadFinished(key, at: download.destination)
            } catch where error is CancellationError || Task.isCancelled {
                self?.modelDownloads[key] = nil
            } catch {
                Log.error("Downloading \(id) failed: \(error.localizedDescription)")
                self?.modelDownloads[key] = .failed("Download failed: \(error.localizedDescription)")
            }
            self?.modelDownloadTasks[key] = nil
        }
        modelDownloadTasks[key] = task
        return task
    }

    /// Stops model `id`'s download; what arrived is kept, so the next one resumes.
    func cancelModelDownload(_ id: String) {
        modelDownloadTasks[ModelDownloadKey(engine: engine, id: id)]?.cancel()
    }

    func isDownloadingModel(_ id: String) -> Bool {
        if case .downloading? = modelDownloads[ModelDownloadKey(engine: engine, id: id)] { return true }
        return false
    }

    /// e.g. "Downloading… 42%"; nil when model `id` isn't downloading.
    func modelDownloadLabel(_ id: String) -> String? {
        guard case .downloading(let fraction)? = modelDownloads[ModelDownloadKey(engine: engine, id: id)] else { return nil }
        return "Downloading… \(Int((fraction * 100).rounded(.down)))%"
    }

    /// Why model `id`'s last download failed; cleared by the next one.
    func modelDownloadError(_ id: String) -> String? {
        guard case .failed(let reason)? = modelDownloads[ModelDownloadKey(engine: engine, id: id)] else { return nil }
        return reason
    }

    /// Whether the engine's model `spec` (reported missing) has a Download
    /// button in the selected engine's list.
    func isDownloadableInApp(_ spec: ModelSpec) -> Bool {
        guard spec.engine == engine else { return false }
        let context = modelContext
        return descriptor.models.contains {
            descriptor.resolve(.named($0.id), in: context).path == spec.path && descriptor.inAppDownload(of: $0.id, in: Paths.modelsDir) != nil
        }
    }

    private func modelDownloadFinished(_ key: ModelDownloadKey, at folder: URL) {
        modelDownloads[key] = nil
        objectWillChange.send()   // the model lists are read from disk
        let selected = ModelSelection.select(configStore.config, environment: environment, engines: engines,
                                             presentFilenames: presentModelFilenames()).spec
        guard URL(fileURLWithPath: selected.path).standardizedFileURL == folder.standardizedFileURL else { return }
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }
}
