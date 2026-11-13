import Foundation

/// A row of the Settings model picker, for the selected engine.
enum ModelRow: Hashable {
    case automatic
    /// A hand-set `modelPath` (or model name) outside the engine's catalog.
    case custom
    case catalog(String)

    /// whisper's row: `modelPath`, else `model`.
    init(_ config: Config) {
        if !config.modelPath.isEmpty {
            self = ModelCatalog.model(forFile: config.modelPath).map { .catalog($0.id) } ?? .custom
        } else if case .named(let id) = config.model {
            self = ModelCatalog.model(id: id) != nil ? .catalog(id) : .custom
        } else {
            self = .automatic
        }
    }

    /// `engine`'s row: its pick (`Config.modelChoice(for:)`) among its models.
    init(_ config: Config, engine: any EngineDescriptor) {
        guard engine.kind != .whisper else { self.init(config); return }
        switch config.modelChoice(for: engine.kind) {
        case .automatic: self = .automatic
        case .named(let id): self = engine.models.contains { $0.id == id } ? .catalog(id) : .custom
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

/// The Settings model section: engine, model (or Automatic), language and
/// keep-warm, each persisted and applied live through `onModelSettingsChange`.
/// What the engine actually runs comes from `currentModel`, never re-derived
/// here.
extension SettingsViewModel {

    // MARK: - Intents

    /// Persists the engine pick and switches to it live (its own model pick,
    /// Automatic by default). Only engines in `engineChoices` can be picked.
    func selectEngine(_ kind: EngineKind) {
        guard kind != engine, engineChoices.contains(kind) else { return }
        configStore.update { $0.engine = kind.rawValue }
        refreshEngine()
        modelSettingsChanged()
    }

    /// Persists the pick (Automatic or a downloaded catalog model of the
    /// selected engine) and switches the engine to it live. Models that
    /// aren't downloaded, and the custom row (set by hand in `config.json`),
    /// can't be picked.
    func selectModel(_ row: ModelRow) {
        guard row != modelRow else { return }
        let choice: ModelChoice
        switch row {
        case .automatic:
            choice = .automatic
        case .custom:
            return
        case .catalog(let id):
            guard descriptor.installedModelIDs(in: modelContext).contains(id) else { return }
            choice = .named(id)
        }
        configStore.update { [engine] in $0.setModelChoice(choice, for: engine) }
        modelRow = row
        modelSettingsChanged()
    }

    /// Persists the decode language (`ModelSpec.autoDetect` or an ISO code);
    /// only multilingual models use it. An engine that doesn't take the
    /// language gives way to whisper until one it does is picked.
    func setLanguage(_ code: String) {
        configStore.update { $0.language = code }
        language = code
        refreshEngine()
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

    // MARK: - Display: engine

    /// The engines offered: runnable on this Mac and taking the current
    /// language (so Turbo shows only for English/EU languages). Always
    /// includes the selected one.
    var engineChoices: [EngineKind] {
        let available = engines.available(in: environment, language: language)
        return available.contains(engine) ? available : [engine] + available
    }

    /// "Using Whisper (whisper.cpp) because …" while the configured engine
    /// can't run, else nil.
    var engineNote: String? {
        ModelSelection.select(configStore.config, environment: environment, engines: engines,
                              presentFilenames: presentModelFilenames()).note
    }

    /// The selected engine's descriptor.
    var descriptor: any EngineDescriptor { engines.descriptor(for: engine) ?? engines.whisper }

    // MARK: - Display: model

    /// What Automatic picks on this Mac (for the current language).
    var recommendedModel: WhisperModel {
        ModelCatalog.recommended(for: hardware, language: configStore.config.language)
    }

    /// The Automatic row: for whisper, naming the model really in use when it
    /// isn't the recommended one; for other engines, the model it resolves to.
    var automaticLabel: String {
        guard engine == .whisper else {
            let context = modelContext
            let auto = descriptor.resolve(.automatic, in: context)
            let label = descriptor.models.first { descriptor.resolve(.named($0.id), in: context) == auto }?.label
            return label.map { "Automatic (\($0))" } ?? "Automatic"
        }
        let recommended = recommendedModel
        guard modelRow == .automatic, let using = ModelCatalog.model(forFile: currentModel().path),
              using != recommended else { return "Automatic (\(recommended.label))" }
        let why = presentModelFilenames().contains(recommended.filename) ? "failed to load" : "not downloaded"
        return "Automatic — using \(using.id) (\(recommended.id) \(why))"
    }

    /// The selected engine's models split by whether they're installed, in
    /// catalog order.
    var modelLists: (downloaded: [EngineModelOption], notDownloaded: [EngineModelOption]) {
        let installed = descriptor.installedModelIDs(in: modelContext)
        let split = Dictionary(grouping: descriptor.models) { installed.contains($0.id) }
        return (split[true] ?? [], split[false] ?? [])
    }

    /// The heading over models that aren't installed.
    var notDownloadedHeading: String {
        engine == .whisper ? "Not downloaded — run: make model MODEL=<name>" : "Not downloaded"
    }

    /// The file name of the custom model, when that row is selected.
    var customModelName: String? {
        modelRow == .custom ? URL(fileURLWithPath: currentModel().path).lastPathComponent : nil
    }

    /// False for whisper's English-only models, which always decode English.
    var isLanguageSelectable: Bool {
        let model = currentModel()
        return model.engine != .whisper || !ModelCatalog.isEnglishOnly(model.path)
    }

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
            switch engines.downloadHint(for: spec) {
            case .command(let command)?: return "Not downloaded. Run: \(command)"
            case .instructions(let text)?: return text
            case nil: return "Model file not found: \(spec.path)"
            }
        case .failed(let reason): return "Failed to load: \(reason)"
        case .verifying: return "Verifying the model's checksum (first use)…"
        case .loading: return "Loading model…"
        case .ready: return modelSwitchError
        case .notLoaded: return nil
        }
    }

    // MARK: - Private

    /// What the selected engine resolves models against.
    private var modelContext: ModelContext {
        let config = configStore.config
        return ModelContext(language: config.language, hardware: hardware, modelsDir: Paths.modelsDir,
                            presentFilenames: presentModelFilenames(),
                            customPath: engine == .whisper ? config.modelPath : "")
    }

    /// Re-derives the selected engine (and its model row) from the config.
    private func refreshEngine() {
        let config = configStore.config
        engine = engines.select(engineID: config.engine, language: config.language, in: environment).kind
        modelRow = ModelRow(config, engine: descriptor)
    }

    private func modelSettingsChanged() {
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }
}
