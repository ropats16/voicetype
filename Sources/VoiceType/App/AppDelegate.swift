import AppKit

/// Menu-bar-only agent. Owns app state, the status item, permission flow, the
/// transcription engine, and the hotkey → dictation wiring.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let permissions = Permissions()
    private let loginItem = LoginItem()

    private var statusItem: NSStatusItem!
    private var hotkeys: HotkeyManager?
    private var dictation: DictationSession?
    /// The model comes from the config (explicit pick, else auto-picked for
    /// this Mac); Settings changes are applied live by `applyModelSettings()`.
    private lazy var engine: TranscriptionEngine = .whisper(
        model: resolvedModel(),
        threads: configStore.config.threads,
        idleUnloadAfter: idleUnloadAfter()
    )
    /// Mic capture. The mic and max duration are read live, so a Settings change
    /// applies to the next recording.
    private lazy var capture = AudioCapture(
        source: MicSource(configuredUID: { [configStore] in configStore.config.microphoneUID }),
        keepWarm: configStore.config.keepMicWarm,
        maxSeconds: { [configStore] in configStore.config.maxRecordingSeconds }
    )
    private var settingsWindowController: SettingsWindowController?
    private weak var settingsViewModel: SettingsViewModel?

    private var readinessTimer: Timer?
    private var isMicWarm = false
    private var hasLoggedReady = false

    private var configIssueCount = 0
    private var hasConfigErrors = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        Paths.ensureDirectories()

        reportConfigIssues()
        setupStatusItem()
        requestPermissionsIfNeeded()
        startEngine()

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

        let hold = NSMenuItem(title: "Hold to talk: \(configStore.config.hold)",
                              action: nil, keyEquivalent: "")
        hold.isEnabled = false
        menu.addItem(hold)

        let toggle = NSMenuItem(title: "Toggle to talk: \(configStore.config.toggle)",
                                action: nil, keyEquivalent: "")
        toggle.isEnabled = false
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let openConfig = NSMenuItem(title: "Open Config File…", action: #selector(openConfig), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let openModels = NSMenuItem(title: "Open Models Folder…", action: #selector(openModelsFolder), keyEquivalent: "")
        openModels.target = self
        menu.addItem(openModels)

        if let hint = engineFixHint {
            let fix = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
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

    /// Disabled menu line telling the user how to fix a model problem, if any.
    private var engineFixHint: String? {
        switch engine.status {
        case .missing: return downloadHint.map { "Model missing — run `\($0)`" } ?? "Model file missing — see Settings"
        case .failed: return "Model failed to load — see log"
        case .notLoaded, .verifying, .loading, .ready: return nil
        }
    }

    private var statusText: String {
        switch engine.status {
        case .missing: return "Model missing"
        case .notLoaded, .loading: return "Loading model…"
        case .verifying: return "Verifying model…"
        case .failed: return "Model failed to load"
        case .ready: break
        }
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
            self?.evaluateReadiness()
        }
        if !permissions.isAccessibilityTrusted(prompt: true) {
            Log.info("Accessibility not yet granted; prompting user.")
        }
    }

    /// With `keepMicWarm` (no Settings UI) the mic runs from the moment mic
    /// permission is granted, so every dictation gets pre-roll. Otherwise it
    /// starts on first use. Attempts once; safe to call repeatedly.
    private func keepMicWarmIfConfigured() {
        guard configStore.config.keepMicWarm, !isMicWarm, permissions.micStatus == .authorized else { return }
        isMicWarm = true
        do { try capture.warmUp() } catch {
            Log.error("Could not keep the microphone warm: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcription engine

    private func startEngine() {
        engine.onStatusChange = { [weak self] status in self?.engineStatusChanged(status) }
        Log.info("Model: \(engine.model.path) (language \(engine.model.language)); auto-pick for this Mac: \(ModelCatalog.recommended(for: .current).id).")
        engine.load()
    }

    private func resolvedModel() -> ModelSpec {
        ModelSelection.resolve(configStore.config, presentFilenames: ModelSelection.presentFilenames())
    }

    private func idleUnloadAfter() -> TimeInterval? {
        ModelSelection.idleUnloadAfter(keepWarm: configStore.config.keepModelWarm,
                                       idleMinutes: configStore.config.modelIdleMinutes,
                                       hardware: .current)
    }

    /// Settings changed the model, language or keep-warm: switch live. Jobs
    /// already submitted finish on the current model.
    private func applyModelSettings() {
        engine.setIdleUnload(after: idleUnloadAfter())
        engine.switchModel(to: resolvedModel())
    }

    /// The command that downloads the engine's model; nil for a custom file.
    private var downloadHint: String? { ModelSelection.downloadCommand(for: engine.model) }

    /// Called on main with each status the engine reports.
    private func engineStatusChanged(_ status: TranscriptionStatus) {
        MainActor.assumeIsolated { settingsViewModel?.modelStatusChanged(status) }
        let path = engine.model.path
        switch status {
        case .missing:
            let fix = downloadHint.map { " Run `\($0)` to download it." } ?? ""
            Log.error("Model not found at \(path).\(fix)")
            Notifier.notify(title: "VoiceType: model not found", body: "Model file not found at \(path).\(fix)")
        case .failed(let reason):
            Log.error("Model load failed: \(reason)")
            // After a failed switch the engine is already back on the previous
            // model (ready); a re-download hint would name the wrong file.
            let stillFailed = { if case .failed = self.engine.status { return true } else { return false } }()
            let fix = stillFailed ? downloadHint.map { " Try `\($0)` to re-download it." } ?? "" : ""
            Notifier.notify(title: "VoiceType: model failed to load", body: "\(reason)\(fix)")
        case .ready:
            Log.info("Transcription model loaded: \(path)")
        case .notLoaded, .verifying, .loading:
            break
        }
        evaluateReadiness()
    }

    // MARK: - Readiness wiring

    private func evaluateReadiness() {
        rebuildMenu()
        keepMicWarmIfConfigured()
        // Dictation may start while a model is loading, verifying or being
        // swapped (jobs queue behind it); only no usable model at all blocks it.
        switch engine.status {
        case .notLoaded, .missing, .failed: return
        case .verifying, .loading, .ready: break
        }
        guard permissions.isAccessibilityTrusted() else { return }

        if dictation == nil { dictation = makeDictationSession() }
        if hotkeys == nil {
            reloadHotkeys()
            if hotkeys == nil {
                return   // tap failed (Accessibility); try again on next tick
            }
        }

        // With keepMicWarm, keep polling until mic permission is granted.
        if configStore.config.keepMicWarm && !isMicWarm { return }

        // Fully wired — stop polling.
        readinessTimer?.invalidate()
        readinessTimer = nil
    }

    /// The dictation flow over the live mic, engine, paste and indicator.
    /// Settings are read live, so a change applies to the next recording.
    private func makeDictationSession() -> DictationSession {
        DictationSession(
            capture: capture,
            engine: EngineDictationAdapter(engine),
            delivery: TextDelivery(),
            feedback: IndicatorFeedback(soundCues: SoundCues(isEnabled: { [configStore] in
                configStore.config.soundCues
            })),
            settings: { [configStore] in
                DictationSettings(maxSeconds: configStore.config.maxRecordingSeconds,
                                  ceilingSeconds: AudioCapture.ceilingSeconds,
                                  trailingSpace: configStore.config.trailingSpace)
            }
        )
    }

    /// Stops any running hotkey tap, builds a fresh `HotkeyManager` from the
    /// current config, forwards its intents to the dictation session, and
    /// starts it. Sets `hotkeys` only if `start()` succeeds (so
    /// `evaluateReadiness()` can detect failure and retry on the next tick).
    private func reloadHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        let manager = HotkeyManager(hold: configStore.config.hold,
                                    toggle: configStore.config.toggle,
                                    cancelKeyCode: configStore.config.cancelKeyCode)
        manager.onHoldStart = { [weak self] in self?.dictation?.handle(.holdDown) }
        manager.onHoldStop = { [weak self] in self?.dictation?.handle(.holdUp) }
        manager.onTogglePress = { [weak self] in self?.dictation?.handle(.toggle) }
        manager.onCancel = { [weak self] in self?.dictation?.handle(.cancel) }
        if manager.start() {
            hotkeys = manager
            // Log only on the first successful wire-up, not on every hotkey rebind.
            if !hasLoggedReady {
                hasLoggedReady = true
                Log.info("VoiceType is ready. Hold \(configStore.config.hold) or press \(configStore.config.toggle) to dictate.")
            }
        } else {
            // start() failed (e.g. Accessibility revoked mid-session). Re-arm the
            // readiness poll so the tap self-recovers once the user re-grants access,
            // without requiring an app restart (I3).
            if readinessTimer == nil {
                readinessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.evaluateReadiness()
                }
            }
        }
    }

    /// Suspends the active hotkey tap without tearing down `dictation`. Used by
    /// Task 4b during live hotkey capture so the tap doesn't swallow the chosen key.
    private func pauseHotkeys() {
        hotkeys?.stop()
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        // Menu actions are always dispatched on the main thread; assume main
        // actor so we can create @MainActor-isolated types synchronously.
        MainActor.assumeIsolated {
            if settingsWindowController == nil {
                let vm = SettingsViewModel(
                    configStore: configStore,
                    loginItem: loginItem,
                    availableMics: { AudioDevices.inputDevices() },
                    presentModelFilenames: { ModelSelection.presentFilenames() },
                    onNeedsMenuRefresh: { [weak self] in self?.rebuildMenu() },
                    pauseHotkeys: { [weak self] in self?.pauseHotkeys() },
                    reloadHotkeys: { [weak self] in self?.reloadHotkeys() },
                    hardware: .current,
                    currentModel: { [engine] in engine.model },
                    modelStatus: engine.status,
                    onModelSettingsChange: { [weak self] in self?.applyModelSettings() }
                )
                settingsViewModel = vm
                settingsWindowController = SettingsWindowController(viewModel: vm)
            }
            settingsWindowController?.show()
        }
    }

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

