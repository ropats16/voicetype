import Foundation

/// A row of the Settings model picker.
enum ModelRow: Hashable {
    case automatic
    /// A hand-set `modelPath` (or model name) outside the catalog.
    case custom
    case catalog(String)

    init(_ config: Config) {
        if !config.modelPath.isEmpty {
            self = ModelCatalog.model(forFile: config.modelPath).map { .catalog($0.id) } ?? .custom
        } else if case .named(let id) = config.model {
            self = ModelCatalog.model(id: id) != nil ? .catalog(id) : .custom
        } else {
            self = .automatic
        }
    }
}

/// The keep-warm setting, as `config.json`'s `keepModelWarm` (unset/true/false).
enum KeepWarmChoice: Hashable, CaseIterable {
    case automatic, always, whenIdle

    init(_ setting: Bool?) {
        switch setting {
        case nil: self = .automatic
        case true?: self = .always
        case false?: self = .whenIdle
        }
    }

    var setting: Bool? {
        switch self {
        case .automatic: return nil
        case .always: return true
        case .whenIdle: return false
        }
    }
}

/// The Settings model section: model (or Automatic), language and keep-warm,
/// each persisted and applied live through `onModelSettingsChange`. What the
/// engine actually runs comes from `currentModel`, never re-derived here.
extension SettingsViewModel {

    // MARK: - Intents

    /// Persists the pick (Automatic or a downloaded catalog model) and switches
    /// the engine to it live. Models that aren't downloaded, and the custom
    /// row (set by hand in `config.json`), can't be picked.
    func selectModel(_ row: ModelRow) {
        guard row != modelRow else { return }
        let choice: ModelChoice
        switch row {
        case .automatic:
            choice = .automatic
        case .custom:
            return
        case .catalog(let id):
            guard let model = ModelCatalog.model(id: id),
                  presentModelFilenames().contains(model.filename) else { return }
            choice = .named(id)
        }
        configStore.update {
            $0.model = choice
            $0.modelPath = ""   // a pick replaces any hand-set file
        }
        modelRow = row
        modelSettingsChanged()
    }

    /// Persists the decode language (`ModelSpec.autoDetect` or an ISO code);
    /// only multilingual models use it.
    func setLanguage(_ code: String) {
        configStore.update { $0.language = code }
        language = code
        modelSettingsChanged()
    }

    func setKeepWarm(_ choice: KeepWarmChoice) {
        configStore.update { $0.keepModelWarm = choice.setting }
        keepWarm = choice
        modelSettingsChanged()
    }

    /// Called (on main) with each engine status, so the section can show it.
    func modelStatusChanged(_ status: TranscriptionStatus) {
        modelStatus = status
        switch status {
        case .failed(let reason): modelSwitchError = reason
        case .loading, .verifying: modelSwitchError = nil
        case .notLoaded, .missing, .ready: break
        }
    }

    // MARK: - Display

    /// What Automatic picks on this Mac (for the current language).
    var recommendedModel: WhisperModel {
        ModelCatalog.recommended(for: hardware, language: configStore.config.language)
    }

    /// The Automatic row, naming the model really in use when it isn't the
    /// recommended one.
    var automaticLabel: String {
        let recommended = recommendedModel
        guard modelRow == .automatic, let using = ModelCatalog.model(forFile: currentModel().path),
              using != recommended else { return "Automatic (\(recommended.label))" }
        let why = presentModelFilenames().contains(recommended.filename) ? "failed to load" : "not downloaded"
        return "Automatic — using \(using.id) (\(recommended.id) \(why))"
    }

    /// Catalog models split by whether they're in the models folder, in catalog order.
    var modelLists: (downloaded: [WhisperModel], notDownloaded: [WhisperModel]) {
        let present = presentModelFilenames()
        let split = Dictionary(grouping: ModelCatalog.models) { present.contains($0.filename) }
        return (split[true] ?? [], split[false] ?? [])
    }

    /// The file name of the custom model, when that row is selected.
    var customModelName: String? {
        modelRow == .custom ? URL(fileURLWithPath: currentModel().path).lastPathComponent : nil
    }

    /// False for English-only models, which always decode English.
    var isLanguageSelectable: Bool { !ModelCatalog.isEnglishOnly(currentModel().path) }

    /// The languages offered for multilingual models, plus a hand-set code from
    /// `config.json` so the picker always shows the truth.
    var languageOptions: [(code: String, name: String)] {
        let common: [(code: String, name: String)] = [
            (ModelSpec.autoDetect, "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
            ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
            ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"),
            ("ar", "Arabic"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ]
        return common.contains { $0.code == language } ? common : common + [(language, language)]
    }

    func label(for choice: KeepWarmChoice) -> String {
        switch choice {
        case .automatic:
            let warm = ModelSelection.isKeptWarm(nil, hardware: hardware)
            return "Automatic (\(warm ? "keep loaded" : "unload when idle") on this Mac)"
        case .always:
            return "Keep loaded"
        case .whenIdle:
            return "Unload after \(Int(max(1, configStore.config.modelIdleMinutes))) min idle"
        }
    }

    /// A one-line explanation of a model problem (or load in progress), else nil.
    var modelStatusHint: String? {
        switch modelStatus {
        case .missing:
            let spec = currentModel()
            return ModelSelection.downloadCommand(for: spec).map { "Not downloaded. Run: \($0)" }
                ?? "Model file not found: \(spec.path)"
        case .failed(let reason): return "Failed to load: \(reason)"
        case .verifying: return "Verifying the model's checksum (first use)…"
        case .loading: return "Loading model…"
        case .ready: return modelSwitchError
        case .notLoaded: return nil
        }
    }

    private func modelSettingsChanged() {
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }
}
