import Foundation
import Combine

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

    // MARK: - Published display state

    @Published private(set) var soundCues: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var selectedMicUID: String?     // nil = System Default
    @Published private(set) var selectedModelSize: String?  // nil if current path unknown
    @Published private(set) var loginError: String?
    @Published private(set) var modelChangeNeedsRestart: Bool = false

    // MARK: - Hotkey display state (Task 4b)

    /// Current hold binding — reflects the persisted config value.
    @Published private(set) var holdBinding: KeyBinding
    /// Current toggle binding — reflects the persisted config value.
    @Published private(set) var toggleBinding: KeyBinding
    /// Non-nil when `ConfigValidator` finds a hold/toggle conflict after a change.
    @Published private(set) var hotkeyWarning: String?
    /// True while a live key-capture session is in progress (global tap is suspended).
    @Published private(set) var isCapturing: Bool = false

    // MARK: - Init

    init(configStore: ConfigStore,
         loginItem: LoginItem,
         availableMics: @escaping () -> [AudioInputDevice],
         presentModelFilenames: @escaping () -> Set<String>,
         onNeedsMenuRefresh: @escaping () -> Void,
         pauseHotkeys: @escaping () -> Void,
         reloadHotkeys: @escaping () -> Void) {
        self.configStore = configStore
        self.loginItem = loginItem
        self.availableMics = availableMics
        self.presentModelFilenames = presentModelFilenames
        self.onNeedsMenuRefresh = onNeedsMenuRefresh
        self.pauseHotkeys = pauseHotkeys
        self.reloadHotkeys = reloadHotkeys
        // Initialise display state from persisted config + current login-item status.
        let cfg = configStore.config
        self.soundCues = cfg.soundCues
        self.launchAtLogin = loginItem.isEnabled
        self.selectedMicUID = cfg.microphoneUID
        self.selectedModelSize = ModelCatalog.selectedSize(modelPath: cfg.modelPath)
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

    /// Persists the selected microphone UID (nil = system default) and triggers a
    /// menu rebuild so the status item reflects the new choice.
    func selectMic(_ uid: String?) {
        configStore.update { $0.microphoneUID = uid }
        selectedMicUID = uid
        onNeedsMenuRefresh()
    }

    /// Persists the selected model path and marks that a restart is required to
    /// load it. Triggers a menu rebuild.
    func selectModel(_ size: String) {
        let path = Paths.modelsDir
            .appendingPathComponent(ModelCatalog.filename(for: size))
            .path
        configStore.update { $0.modelPath = path }
        selectedModelSize = size
        modelChangeNeedsRestart = true
        onNeedsMenuRefresh()
    }

    // MARK: - Computed properties for the View

    /// All currently available audio input devices (re-queried each access).
    var micOptions: [AudioInputDevice] { availableMics() }

    /// Full model catalog with download status (re-queried each access).
    var modelEntries: [ModelCatalogEntry] { ModelCatalog.entries(presentFilenames: presentModelFilenames()) }

    /// Human-readable label for the current hold binding (e.g. "⌃⇧").
    var holdDescription: String   { HotkeyDescription.describe(holdBinding) }
    /// Human-readable label for the current toggle binding (e.g. "⌃⌥Space").
    var toggleDescription: String { HotkeyDescription.describe(toggleBinding) }

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

    /// Resets a binding to its documented default (hold → ⌃⇧, toggle → ⌃⌥Space).
    /// This is the "combo didn't work" fallback; applies live and refreshes the menu.
    func resetHotkey(_ target: HotkeyTarget) {
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
