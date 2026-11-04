import Foundation
import Combine

/// One row of the "Max dictation length" picker.
struct MaxDictationChoice: Hashable {
    let seconds: Double
    let label: String
}

/// Which hotkey binding is being edited or captured.
enum HotkeyTarget { case hold, toggle }

/// View-model for the settings window. `@MainActor` so `@Published` mutations
/// are always on the main thread and SwiftUI bindings update correctly.
///
/// Every external dependency is injected so the class is fully testable without
/// UI, audio hardware, or a real login-item service.
@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: - Dependencies

    private let configStore: ConfigStore
    private let loginItem: LoginItem
    private let availableMics: () -> [AudioInputDevice]
    private let presentModelFilenames: () -> Set<String>
    private let onNeedsMenuRefresh: () -> Void
    /// Stored for Task 4b (hotkey capture); not used by this task's UI.
    private let pauseHotkeys: () -> Void
    /// Stored for Task 4b (hotkey capture); not used by this task's UI.
    private let reloadHotkeys: () -> Void
    private let hardware: HardwareProfile
    /// Re-resolves the model settings and hands them to the engine (live switch).
    private let onModelSettingsChange: () -> Void

    // MARK: - Published display state

    @Published private(set) var soundCues: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var selectedMicUID: String?     // nil = System Default
    /// The picker selection: the configured max dictation length (0 = no limit).
    @Published private(set) var maxDictationSeconds: Double
    @Published private(set) var loginError: String?

    // MARK: - Model display state

    /// `ModelSelection.automatic`, a catalog id, or `customModelID`.
    @Published private(set) var selectedModelID: String
    @Published private(set) var language: String
    /// The effective keep-warm setting (the automatic default until the user picks).
    @Published private(set) var keepModelWarm: Bool
    @Published private(set) var modelStatus: TranscriptionStatus

    // MARK: - Hotkey display state (Task 4b)

    /// Current hold binding — reflects the persisted config value.
    @Published private(set) var holdBinding: KeyBinding
    /// Current toggle binding — reflects the persisted config value.
    @Published private(set) var toggleBinding: KeyBinding
    /// Non-nil when `ConfigValidator` finds a hold/toggle conflict after a change.
    @Published private(set) var hotkeyWarning: String?
    /// True while a live key-capture session is in progress (global tap is suspended).
    @Published private(set) var isCapturing: Bool = false

    // MARK: - Hotkey recorder (owned here so SettingsWindowController can tear it down)

    /// Single, stable `HotkeyRecorder` instance. Owned by the VM (which outlives
    /// individual window-close/reopen cycles) so `SettingsWindowController` can
    /// reach it via `cancelCapture()` from `windowWillClose(_:)`.
    let recorder = HotkeyRecorder()

    // MARK: - Init

    init(configStore: ConfigStore,
         loginItem: LoginItem,
         availableMics: @escaping () -> [AudioInputDevice],
         presentModelFilenames: @escaping () -> Set<String>,
         onNeedsMenuRefresh: @escaping () -> Void,
         pauseHotkeys: @escaping () -> Void,
         reloadHotkeys: @escaping () -> Void,
         hardware: HardwareProfile = .current,
         modelStatus: TranscriptionStatus = .notLoaded,
         onModelSettingsChange: @escaping () -> Void = {}) {
        self.configStore = configStore
        self.loginItem = loginItem
        self.availableMics = availableMics
        self.presentModelFilenames = presentModelFilenames
        self.onNeedsMenuRefresh = onNeedsMenuRefresh
        self.pauseHotkeys = pauseHotkeys
        self.reloadHotkeys = reloadHotkeys
        self.hardware = hardware
        self.onModelSettingsChange = onModelSettingsChange
        // Initialise display state from persisted config + current login-item status.
        let cfg = configStore.config
        self.soundCues = cfg.soundCues
        self.launchAtLogin = loginItem.isEnabled
        self.selectedMicUID = cfg.microphoneUID
        self.maxDictationSeconds = max(0, cfg.maxRecordingSeconds)
        self.selectedModelID = Self.modelID(for: cfg)
        self.language = cfg.language
        self.keepModelWarm = ModelSelection.idleUnloadAfter(keepWarm: cfg.keepModelWarm,
                                                            idleMinutes: cfg.modelIdleMinutes,
                                                            hardware: hardware) == nil
        self.modelStatus = modelStatus
        self.holdBinding = cfg.hold
        self.toggleBinding = cfg.toggle
    }

    // MARK: - Intent methods (call from the View; avoids two-way Binding loops)

    /// Persists the sound-cues preference and updates the published value.
    func setSoundCues(_ on: Bool) {
        configStore.update { $0.soundCues = on }
        soundCues = on
    }

    /// Registers or unregisters the login item. On failure the toggle is reverted
    /// and `loginError` is set (catches SMAppService throws in dev/non-bundled context).
    func setLaunchAtLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
            launchAtLogin = on
            loginError = nil
        } catch {
            // launchAtLogin was never changed (it's only set in the success branch); writing
            // loginError publishes a change, so SwiftUI re-renders and the toggle snaps back.
            loginError = "Could not \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }

    /// Persists the max dictation length (0 = no limit). Read at each start.
    func setMaxDictationSeconds(_ seconds: Double) {
        configStore.update { $0.maxRecordingSeconds = seconds }
        maxDictationSeconds = seconds
    }

    /// Persists the selected microphone UID (nil = system default) and triggers a
    /// menu rebuild so the status item reflects the new choice.
    func selectMic(_ uid: String?) {
        configStore.update { $0.microphoneUID = uid }
        selectedMicUID = uid
        onNeedsMenuRefresh()
    }

    /// Persists the pick (`ModelSelection.automatic` or a downloaded catalog
    /// id) and switches the engine to it live. A pick of a model that isn't
    /// downloaded is ignored (downloading is outside the app for now).
    func selectModel(_ id: String) {
        guard id != selectedModelID else { return }
        if id != ModelSelection.automatic {
            guard let model = ModelCatalog.model(id: id),
                  presentModelFilenames().contains(model.filename) else { return }
        }
        configStore.update {
            $0.model = id
            $0.modelPath = ""   // a pick replaces any hand-set file
        }
        selectedModelID = id
        modelSettingsChanged()
    }

    /// Persists the decode language ("auto" or an ISO code); only multilingual
    /// models use it.
    func setLanguage(_ code: String) {
        configStore.update { $0.language = code }
        language = code
        modelSettingsChanged()
    }

    /// Persists an explicit keep-warm choice (overriding the automatic default).
    func setKeepModelWarm(_ on: Bool) {
        configStore.update { $0.keepModelWarm = on }
        keepModelWarm = on
        modelSettingsChanged()
    }

    /// Called (on main) with each engine status, so the section can show it.
    func modelStatusChanged(_ status: TranscriptionStatus) {
        modelStatus = status
    }

    // MARK: - Computed properties for the View

    /// The fixed lengths, plus the configured one as a "custom" row when it was
    /// hand-edited to something else, so the picker always shows the truth.
    var maxDictationChoices: [MaxDictationChoice] {
        var seconds = DictationLimit.choices
        let current = maxDictationSeconds
        if !seconds.contains(current) {
            seconds.insert(current, at: seconds.firstIndex { $0 <= 0 || $0 > current } ?? seconds.endIndex)
        }
        return seconds.map { s in
            let label = DictationLimit.label(s)
            return MaxDictationChoice(seconds: s, label: DictationLimit.choices.contains(s) ? label : "\(label) (custom)")
        }
    }

    /// All currently available audio input devices (re-queried each access).
    var micOptions: [AudioInputDevice] { availableMics() }

    /// The `selectedModelID` of a hand-set `modelPath` outside the catalog.
    static let customModelID = "custom"

    /// What Automatic picks on this Mac (for the current language).
    var recommendedModel: WhisperModel {
        ModelCatalog.recommended(for: hardware, language: configStore.config.language)
    }

    /// Catalog models in the models folder (re-queried each access).
    var downloadedModels: [WhisperModel] {
        let present = presentModelFilenames()
        return ModelCatalog.models.filter { present.contains($0.filename) }
    }

    /// Catalog models not yet downloaded, shown with the command that fetches them.
    var notDownloadedModels: [WhisperModel] {
        let present = presentModelFilenames()
        return ModelCatalog.models.filter { !present.contains($0.filename) }
    }

    /// The file name of a hand-set `modelPath` outside the catalog, if any.
    var customModelName: String? {
        selectedModelID == Self.customModelID
            ? URL(fileURLWithPath: configStore.config.modelPath).lastPathComponent : nil
    }

    /// What the engine runs for the current settings.
    private var resolvedModel: ModelSpec {
        ModelSelection.resolve(configStore.config, hardware: hardware, presentFilenames: presentModelFilenames())
    }

    /// False for English-only models, which always decode English.
    var isLanguageSelectable: Bool { !isEnglishOnly(resolvedModel) }

    /// The languages offered for multilingual models ("auto" = detect), plus a
    /// hand-set code from `config.json` so the picker always shows the truth.
    var languageOptions: [(code: String, name: String)] {
        let common: [(code: String, name: String)] = [
            ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
            ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
            ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"),
            ("ar", "Arabic"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ]
        return common.contains { $0.code == language } ? common : common + [(language, language)]
    }

    /// A one-line explanation of a model problem (or load in progress), else nil.
    var modelStatusHint: String? {
        switch modelStatus {
        case .missing:
            let name = ModelCatalog.model(forFile: resolvedModel.path)?.id
            return name.map { "Not downloaded. Run: make model MODEL=\($0)" } ?? "Model file not found."
        case .failed(let reason): return "Failed to load: \(reason)"
        case .loading: return "Loading model…"
        case .notLoaded, .ready: return nil
        }
    }

    /// Human-readable label for the current hold binding (e.g. "⌃⇧").
    var holdDescription: String   { holdBinding.description }
    /// Human-readable label for the current toggle binding (e.g. "⌃⌥Space").
    var toggleDescription: String { toggleBinding.description }

    // MARK: - Hotkey intent methods (Task 4b)

    /// Suspends the global event tap so keys pressed during capture don't fire
    /// dictation. Sets `isCapturing` so the UI can show its "Recording…" state.
    func beginHotkeyCapture() {
        pauseHotkeys()
        isCapturing = true
    }

    /// Commits a captured binding (or cancels if `binding` is nil). Persists the
    /// new value for `target`, re-registers the event tap, refreshes the menu, and
    /// recomputes `hotkeyWarning`. On cancel (`nil`), only the tap is resumed.
    func commitHotkey(_ binding: KeyBinding?, for target: HotkeyTarget) {
        if let binding {
            switch target {
            case .hold:
                configStore.update { $0.hold = binding }
                holdBinding = binding
            case .toggle:
                configStore.update { $0.toggle = binding }
                toggleBinding = binding
            }
            isCapturing = false
            reloadHotkeys()
            onNeedsMenuRefresh()
            updateHotkeyWarning()
        } else {
            // User cancelled — resume the tap with the config unchanged.
            isCapturing = false
            reloadHotkeys()
        }
    }

    /// Cancels any in-progress capture: removes the NSEvent monitor, clears
    /// `captureTarget`, and resumes the global tap. No-op when idle.
    /// Called by `SettingsWindowController.windowWillClose(_:)` as the reliable
    /// teardown path for the mid-capture window-close scenario (C1).
    func cancelCapture() {
        recorder.cancelCapture(vm: self)
    }

    /// Resets a binding to its documented default (hold → ⌃⇧, toggle → ⌃⌥Space).
    /// This is the "combo didn't work" fallback; applies live and refreshes the menu.
    func resetHotkey(_ target: HotkeyTarget) {
        // Cancel any active capture first so the recorder monitor is removed before
        // we reload the tap. No-op if idle; handles the case where the OTHER row's
        // capture is in progress (I2).
        recorder.cancelCapture(vm: self)
        switch target {
        case .hold:
            let binding = KeyBinding.controlShift
            configStore.update { $0.hold = binding }
            holdBinding = binding
        case .toggle:
            let binding = KeyBinding.controlOptionSpace
            configStore.update { $0.toggle = binding }
            toggleBinding = binding
        }
        isCapturing = false
        reloadHotkeys()
        onNeedsMenuRefresh()
        updateHotkeyWarning()
    }

    // MARK: - Private helpers

    private func modelSettingsChanged() {
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }

    private static func modelID(for config: Config) -> String {
        guard !config.modelPath.isEmpty else { return config.model.isEmpty ? ModelSelection.automatic : config.model }
        return ModelCatalog.model(forFile: config.modelPath)?.id ?? customModelID
    }

    private func isEnglishOnly(_ spec: ModelSpec) -> Bool {
        ModelCatalog.model(forFile: spec.path)?.isEnglishOnly
            ?? URL(fileURLWithPath: spec.path).lastPathComponent.contains(".en")
    }

    /// Surfaces the first hold/toggle config issue as a user-visible warning.
    private func updateHotkeyWarning() {
        let issues = ConfigValidator.validate(configStore.config)
        hotkeyWarning = issues.first {
            $0.message.contains("hold") || $0.message.contains("toggle")
        }?.message
    }
}
