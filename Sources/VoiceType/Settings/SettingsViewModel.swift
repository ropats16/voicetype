import Foundation
import Combine

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
            // Revert the toggle to the previous value.
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
}
