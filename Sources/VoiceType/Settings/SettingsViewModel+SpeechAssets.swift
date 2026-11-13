import Foundation

/// Settings' model section for Apple Speech: the OS manages its model, so in
/// place of a model list it shows the language's asset state and a Download
/// button. When a download lands the model settings are re-applied, and the
/// engine (reporting `.missing` until then) loads the model.
extension SettingsViewModel {

    /// Re-reads the asset state for the selected engine and language (on
    /// appear, and when either changes); nil for engines with model files.
    func refreshSpeechAssets() async {
        guard engine == .appleSpeech else { speechAssetState = nil; return }
        let language = self.language
        let state = await speechAssets.state(language: language)
        guard engine == .appleSpeech, self.language == language else { return }   // changed meanwhile
        speechAssetState = state
    }

    /// Downloads the language's model (only when it's downloadable), showing
    /// progress; on success re-applies the model settings so the engine
    /// reloads, on failure says why.
    func downloadSpeechModel() async {
        guard canDownloadSpeechModel else { return }
        speechAssetError = nil
        speechAssetState = .downloading(progress: 0)
        do {
            try await speechAssets.install(language: language) { fraction in
                Task { @MainActor [weak self] in
                    // A late report mustn't undo the finished state.
                    guard let self, case .downloading = self.speechAssetState else { return }
                    self.speechAssetState = .downloading(progress: fraction)
                }
            }
        } catch {
            speechAssetError = "Download failed: \(error.localizedDescription)"
            speechAssetState = nil
            await refreshSpeechAssets()
            return
        }
        speechAssetState = nil
        await refreshSpeechAssets()
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }

    /// e.g. "Downloaded", "Not downloaded", "Downloading… 42%"; nil when not
    /// Apple Speech.
    var speechAssetLabel: String? {
        switch speechAssetState {
        case nil: return nil
        case .installed?: return "Downloaded"
        case .notInstalled?: return "Not downloaded"
        case .downloading(let progress?)?: return "Downloading… \(Int((progress * 100).rounded()))%"
        case .downloading(nil)?: return "Downloading…"
        case .unsupported?: return "Not available for \(EngineRegistry.languageName(language)) on this Mac"
        }
    }

    var canDownloadSpeechModel: Bool { speechAssetState == .notInstalled }
}
