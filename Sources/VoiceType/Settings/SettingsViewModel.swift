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

    let configStore: ConfigStore
    private let loginItem: LoginItem
    private let availableMics: () -> [AudioInputDevice]
    let presentModelFilenames: () -> Set<String>
    let onNeedsMenuRefresh: () -> Void
    /// Stored for Task 4b (hotkey capture); not used by this task's UI.
    private let pauseHotkeys: () -> Void
    /// Stored for Task 4b (hotkey capture); not used by this task's UI.
    private let reloadHotkeys: () -> Void
    let hardware: HardwareProfile
    /// The model the engine is actually running (Automatic may fall back).
    let currentModel: () -> ModelSpec
    /// Re-resolves the model settings and hands them to the engine (live switch).
    let onModelSettingsChange: () -> Void

    // MARK: - Published display state

    @Published private(set) var soundCues: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var selectedMicUID: String?     // nil = System Default
    /// The picker selection: the configured max dictation length (0 = no limit).
    @Published private(set) var maxDictationSeconds: Double
    @Published private(set) var loginError: String?

    // MARK: - Model display state

    // Intents and derived values: SettingsViewModel+Model.swift.
    @Published var modelRow: ModelRow
    @Published var language: String
    @Published var keepWarm: KeepWarmChoice
    @Published var modelStatus: TranscriptionStatus
    /// The last failed switch (the engine went back to the previous model);
    /// cleared by the next load or settings change.
    @Published var modelSwitchError: String?

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
         hardware: HardwareProfile,
         currentModel: @escaping () -> ModelSpec,
         modelStatus: TranscriptionStatus,
         onModelSettingsChange: @escaping () -> Void) {
        self.configStore = configStore
        self.loginItem = loginItem
        self.availableMics = availableMics
        self.presentModelFilenames = presentModelFilenames
        self.onNeedsMenuRefresh = onNeedsMenuRefresh
        self.pauseHotkeys = pauseHotkeys
        self.reloadHotkeys = reloadHotkeys
        self.hardware = hardware
        self.currentModel = currentModel
        self.onModelSettingsChange = onModelSettingsChange
        // Initialise display state from persisted config + current login-item status.
        let cfg = configStore.config
        self.soundCues = cfg.soundCues
        self.launchAtLogin = loginItem.isEnabled
        self.selectedMicUID = cfg.microphoneUID
        self.maxDictationSeconds = max(0, cfg.maxRecordingSeconds)
        self.modelRow = ModelRow(cfg)
        self.language = cfg.language
        self.keepWarm = KeepWarmChoice(cfg.keepModelWarm)
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

    /// Persists the selected microphone UID (nil = system default) and refreshes
    /// the status menu.
    func selectMic(_ uid: String?) {
        configStore.update { $0.microphoneUID = uid }
        selectedMicUID = uid
        onNeedsMenuRefresh()
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

    /// Surfaces the first hold/toggle config issue as a user-visible warning.
    private func updateHotkeyWarning() {
        let issues = ConfigValidator.validate(configStore.config)
        hotkeyWarning = issues.first {
            $0.message.contains("hold") || $0.message.contains("toggle")
        }?.message
    }
}
