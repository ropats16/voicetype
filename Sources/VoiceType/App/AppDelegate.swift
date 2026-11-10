import AppKit

/// Menu-bar-only agent: wires the readiness monitor, status menu, transcription
/// engine, hotkeys and dictation session together. Rules live in those
/// modules (`ReadinessMonitor`, `DictationSession`, …); this only connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let permissions = Permissions()
    private let loginItem = LoginItem()

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
    private lazy var monitor = ReadinessMonitor(probe: permissions, clock: SystemDictationClock(),
                                                engine: EngineReadiness(engine))
    private lazy var dictation = makeDictationSession()
    private var menu: StatusMenu!
    private var hotkeys: HotkeyManager?
    private var settingsWindowController: SettingsWindowController?
    private weak var settingsViewModel: SettingsViewModel?

    private var configIssues: [ConfigIssue] = []
    private var isMicWarm = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        Paths.ensureDirectories()

        reportConfigIssues()
        setupMenu()
        wireMonitor()
        startEngine()
        requestPermissionsIfNeeded()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotkeys?.stop()
    }

    // MARK: - Status menu

    private func setupMenu() {
        menu = StatusMenu()
        menu.onAction = { [weak self] action in self?.perform(action) }
        menu.onOpenSettings = { [weak self] in self?.openSettings() }
        menu.onOpenConfig = { [weak self] in self?.openConfig() }
        // Re-read permissions on open: a mic change while Accessibility is
        // denied leaves the status alone but changes a row.
        menu.onWillOpen = { [weak self] in self?.monitor.recheck(); self?.refreshMenu() }
    }

    private func refreshMenu() {
        let config = configStore.config
        menu.render(StatusMenuContent(status: monitor.status, inputs: monitor.inputs,
                                      hold: "\(config.hold)", toggle: "\(config.toggle)",
                                      configIssues: configIssues))
    }

    /// Logs each invalid/conflicting binding (errors via `Log.error`, warnings
    /// via `Log.info`); the menu summarises them. Reporting only.
    private func reportConfigIssues() {
        configIssues = ConfigValidator.validate(configStore.config)
        for issue in configIssues {
            switch issue.severity {
            case .error:   Log.error("Config issue: \(issue.message)")
            case .warning: Log.info("Config issue: \(issue.message)")
            }
        }
    }

    // MARK: - Readiness

    private func wireMonitor() {
        monitor.onInputsChange = { [weak self] inputs in
            self?.refreshMenu()
            if inputs.microphone == .authorized { self?.keepMicWarmIfConfigured() }
        }
        monitor.onChange = { status in
            if case .notReady(let issue) = status { Log.info("Not ready: \(issue.title). \(issue.detail)") }
        }
        monitor.onBecameReady = { [weak self] isFirst in
            guard isFirst, let config = self?.configStore.config else { return }
            Log.info("VoiceType is ready. Hold \(config.hold) or press \(config.toggle) to dictate.")
        }
        monitor.onTapNeeded = { [weak self] in self?.reloadHotkeys() }
    }

    private func requestPermissionsIfNeeded() {
        permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        if !permissions.isAccessibilityTrusted(prompt: true) {
            Log.info("Accessibility not yet granted; prompting user.")
        }
    }

    private func perform(_ action: ReadinessAction) {
        switch action {
        case .openAccessibilitySettings:
            _ = permissions.isAccessibilityTrusted(prompt: true)
            permissions.openAccessibilitySettings()
        case .openMicrophoneSettings:
            permissions.openMicrophoneSettings()
        case .requestMicrophone:
            permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        case .openModelsFolder:
            Paths.ensureDirectories()
            NSWorkspace.shared.open(Paths.modelsDir)
        }
    }

    /// With `keepMicWarm` (no Settings UI) the mic runs from the moment mic
    /// permission is granted, so every dictation gets pre-roll. Otherwise it
    /// starts on first use. Attempts once.
    private func keepMicWarmIfConfigured() {
        guard configStore.config.keepMicWarm, !isMicWarm else { return }
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

    /// Called on main with each status the engine reports.
    private func engineStatusChanged(_ status: TranscriptionStatus) {
        MainActor.assumeIsolated { settingsViewModel?.modelStatusChanged(status) }
        let readiness = EngineReadiness(engine)
        let path = engine.model.path
        switch status {
        case .missing:
            let fix = readiness.downloadCommand.map { " Run `\($0)` to download it." } ?? ""
            Log.error("Model not found at \(path).\(fix)")
            Notifier.notify(title: "VoiceType: model not found", body: "Model file not found at \(path).\(fix)")
        case .failed(let reason):
            Log.error("Model load failed: \(reason)")
            // After a failed switch the engine is already back on the previous
            // model (ready); a re-download hint would name the wrong file.
            let stillFailed = { if case .failed = readiness.status { return true } else { return false } }()
            let fix = stillFailed ? readiness.downloadCommand.map { " Try `\($0)` to re-download it." } ?? "" : ""
            Notifier.notify(title: "VoiceType: model failed to load", body: "\(reason)\(fix)")
        case .ready:
            Log.info("Transcription model loaded: \(path)")
        case .notLoaded, .verifying, .loading:
            break
        }
        monitor.engineChanged(readiness)
    }

    // MARK: - Dictation & hotkeys

    /// The dictation flow over the live mic, engine, paste and indicator.
    /// Settings are read live, so a change applies to the next recording; a
    /// press only starts one when readiness allows (re-checked per press).
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
            },
            readiness: { [weak self] in
                guard let monitor = self?.monitor else { return .ready }
                monitor.recheck()
                return monitor.status
            }
        )
    }

    /// (Re)installs the hotkey tap from the current config and reports the
    /// outcome to the monitor, which retries a failure on its next poll.
    private func reloadHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        let config = configStore.config
        let manager = HotkeyManager(hold: config.hold, toggle: config.toggle, cancelKeyCode: config.cancelKeyCode)
        manager.onHoldStart = { [weak self] in self?.dictation.handle(.holdDown) }
        manager.onHoldStop = { [weak self] in self?.dictation.handle(.holdUp) }
        manager.onTogglePress = { [weak self] in self?.dictation.handle(.toggle) }
        manager.onCancel = { [weak self] in self?.dictation.handle(.cancel) }
        let started = manager.start()
        if started { hotkeys = manager }
        monitor.hotkeyTapChanged(started ? .installed : .failed)
    }

    // MARK: - Menu actions

    private func openSettings() {
        // Menu actions are always dispatched on the main thread; assume main
        // actor so we can create @MainActor-isolated types synchronously.
        MainActor.assumeIsolated {
            if settingsWindowController == nil {
                let vm = SettingsViewModel(
                    configStore: configStore,
                    loginItem: loginItem,
                    availableMics: { AudioDevices.inputDevices() },
                    presentModelFilenames: { ModelSelection.presentFilenames() },
                    onNeedsMenuRefresh: { [weak self] in self?.refreshMenu() },
                    // Suspends the tap during live hotkey capture so it doesn't
                    // swallow the chosen key; `reloadHotkeys` brings it back.
                    pauseHotkeys: { [weak self] in self?.hotkeys?.stop() },
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

    private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { configStore.save() }
        NSWorkspace.shared.open(Paths.configFile)
    }
}
