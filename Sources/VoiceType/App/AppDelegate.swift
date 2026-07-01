import AppKit

/// Menu-bar-only agent. Owns app state, the status item, permission flow, model
/// loading, and the hotkey → dictation wiring.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let permissions = Permissions()

    private var statusItem: NSStatusItem!
    private var hotkeys: HotkeyManager?
    private var dictation: DictationController?
    private var transcriber: Transcriber?

    private var readinessTimer: Timer?

    private enum State {
        case loadingModel
        case modelMissing
        case needsAccessibility
        case needsMicrophone
        case ready
    }
    private var modelLoaded = false
    private var modelMissing = false
    private var configIssueCount = 0
    private var hasConfigErrors = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        Paths.ensureDirectories()

        reportConfigIssues()
        setupStatusItem()
        requestPermissionsIfNeeded()
        loadModelAsync()

        // Re-check readiness until everything is wired (catches the user
        // granting Accessibility/Microphone while the app is already running).
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluateReadiness()
        }
        evaluateReadiness()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceType")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "VoiceType — \(statusText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let mic = NSMenuItem(
            title: "Microphone: \(permissions.micStatus == .authorized ? "Granted" : "Not granted")",
            action: permissions.micStatus == .authorized ? nil : #selector(openMicSettings),
            keyEquivalent: ""
        )
        mic.target = self
        menu.addItem(mic)

        let ax = NSMenuItem(
            title: "Accessibility: \(permissions.isAccessibilityTrusted() ? "Granted" : "Not granted")",
            action: permissions.isAccessibilityTrusted() ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        ax.target = self
        menu.addItem(ax)

        menu.addItem(.separator())

        let hold = NSMenuItem(title: "Hold to talk: \(HotkeyDescription.describe(configStore.config.hold))",
                              action: nil, keyEquivalent: "")
        hold.isEnabled = false
        menu.addItem(hold)

        let toggle = NSMenuItem(title: "Toggle to talk: \(HotkeyDescription.describe(configStore.config.toggle))",
                                action: nil, keyEquivalent: "")
        toggle.isEnabled = false
        menu.addItem(toggle)

        let openConfig = NSMenuItem(title: "Open Config File…", action: #selector(openConfig), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let openModels = NSMenuItem(title: "Open Models Folder…", action: #selector(openModelsFolder), keyEquivalent: "")
        openModels.target = self
        menu.addItem(openModels)

        if modelMissing {
            let fix = NSMenuItem(title: "Model missing — run `make setup`", action: nil, keyEquivalent: "")
            fix.isEnabled = false
            menu.addItem(fix)
        }

        if hasConfigErrors {
            let configIssue = NSMenuItem(title: "⚠️ Config: \(configIssueCount) config issue(s) — see log", action: nil, keyEquivalent: "")
            configIssue.isEnabled = false
            menu.addItem(configIssue)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private var statusText: String {
        if modelMissing { return "Model missing" }
        if !modelLoaded { return "Loading model…" }
        if !permissions.isAccessibilityTrusted() { return "Needs Accessibility" }
        if permissions.micStatus != .authorized { return "Needs Microphone" }
        return "Ready"
    }

    // MARK: - Config validation

    /// Inspects the loaded config for invalid/conflicting bindings and logs each
    /// issue (errors via `Log.error`, warnings via `Log.info`). Reporting only —
    /// the config is never modified. If any error exists, `rebuildMenu()` shows a
    /// single disabled line summarising the count.
    private func reportConfigIssues() {
        let issues = ConfigValidator.validate(configStore.config)
        for issue in issues {
            switch issue.severity {
            case .error:   Log.error("Config issue: \(issue.message)")
            case .warning: Log.info("Config issue: \(issue.message)")
            }
        }
        configIssueCount = issues.count
        hasConfigErrors = issues.contains { $0.severity == .error }
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        permissions.requestMicrophone { [weak self] _ in
            self?.rebuildMenu()
        }
        if !permissions.isAccessibilityTrusted(prompt: true) {
            Log.info("Accessibility not yet granted; prompting user.")
        }
    }

    // MARK: - Model loading

    private func loadModelAsync() {
        let path = configStore.config.modelPath
        guard FileManager.default.fileExists(atPath: path) else {
            modelMissing = true
            Log.error("Model not found at \(path). Run `make setup`.")
            Notifier.notify(
                title: "VoiceType: model not found",
                body: "Model file not found at \(path). Run `make setup` to download it."
            )
            rebuildMenu()
            return
        }
        let language = configStore.config.language
        let threads = configStore.config.threads
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let t = try WhisperTranscriber(modelPath: path, language: language, threads: threads)
                DispatchQueue.main.async {
                    self?.transcriber = t
                    self?.modelLoaded = true
                    Log.info("Whisper model loaded.")
                    self?.evaluateReadiness()
                    self?.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.modelMissing = true
                    Log.error("Model load failed: \(error.localizedDescription)")
                    Notifier.notify(
                        title: "VoiceType: model failed to load",
                        body: "\(error.localizedDescription) Try `make setup` or `make model MODEL=<name>` to re-download it."
                    )
                    self?.rebuildMenu()
                }
            }
        }
    }

    // MARK: - Readiness wiring

    private func evaluateReadiness() {
        rebuildMenu()
        guard let transcriber, modelLoaded else { return }
        guard permissions.isAccessibilityTrusted() else { return }

        if dictation == nil {
            dictation = DictationController(transcriber: transcriber, configStore: configStore)
        }
        if hotkeys == nil {
            let manager = HotkeyManager(hold: configStore.config.hold, toggle: configStore.config.toggle,
                                        cancelKeyCode: configStore.config.cancelKeyCode)
            manager.onHoldStart = { [weak self] in self?.dictation?.startRecording() }
            manager.onHoldStop = { [weak self] in self?.dictation?.stopRecordingAndTranscribe() }
            manager.onTogglePress = { [weak self] in self?.dictation?.toggleRecording() }
            manager.onCancel = { [weak self] in self?.dictation?.cancelRecording() }
            if manager.start() {
                hotkeys = manager
                Log.info("VoiceType is ready. Hold \(HotkeyDescription.describe(configStore.config.hold)) or press \(HotkeyDescription.describe(configStore.config.toggle)) to dictate.")
            } else {
                return   // tap failed (Accessibility); try again on next tick
            }
        }

        // Fully wired — stop polling.
        readinessTimer?.invalidate()
        readinessTimer = nil
    }

    // MARK: - Menu actions

    @objc private func openMicSettings() { permissions.openMicrophoneSettings() }
    @objc private func openAccessibilitySettings() {
        _ = permissions.isAccessibilityTrusted(prompt: true)
        permissions.openAccessibilitySettings()
    }
    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { configStore.save() }
        NSWorkspace.shared.open(Paths.configFile)
    }
    @objc private func openModelsFolder() {
        Paths.ensureDirectories()
        NSWorkspace.shared.open(Paths.modelsDir)
    }
}

/// Human-readable key binding labels for the menu.
enum HotkeyDescription {
    static func describe(_ binding: KeyBinding) -> String {
        // Pure modifier combo (no main key), e.g. fn+Shift.
        if binding.keyCode < 0 {
            return binding.modifiers.map { symbol(for: $0) }.joined(separator: " ")
        }
        if binding.modifiers.isEmpty, let name = modifierKeyName(binding.keyCode) {
            return name
        }
        let mods = binding.modifiers.map { symbol(for: $0) }.joined()
        return mods + keyName(binding.keyCode)
    }

    private static func modifierKeyName(_ keyCode: Int) -> String? {
        switch keyCode {
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        default: return nil
        }
    }

    private static func symbol(for modifier: String) -> String {
        switch modifier {
        case "command": return "⌘"
        case "option": return "⌥"
        case "control": return "⌃"
        case "shift": return "⇧"
        case "function", "fn", "globe": return "fn"
        default: return ""
        }
    }

    private static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 53: return "Esc"
        default: return "key\(keyCode)"
        }
    }
}
