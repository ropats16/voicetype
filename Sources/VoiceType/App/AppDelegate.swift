import AppKit

/// Menu-bar-only agent: wires the readiness monitor, status menu, transcription
/// engine, hotkeys and dictation session together. Rules live in those
/// modules (`ReadinessMonitor`, `DictationSession`, …); this only connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let permissions = Permissions()
    private let loginItem = LoginItem()

    /// The engine and model come from the config (the configured engine if it
    /// can run here, else whisper; an explicit pick, else auto-picked for this
    /// Mac); Settings changes are applied live by `applyModelSettings()`.
    private lazy var engine: TranscriptionEngine = .registered(
        model: resolvedModel(),
        options: EngineOptions(threads: configStore.config.threads),
        idleUnloadAfter: idleUnloadAfter()
    )
    /// The last engine-fallback note logged, so a re-resolve doesn't repeat it.
    private var loggedFallback: String?
    /// Mic capture. The mic and max duration are read live, so a Settings change
    /// applies to the next recording.
    private lazy var capture = AudioCapture(
        source: MicSource(configuredUID: { [configStore] in configStore.config.microphoneUID }),
        keepWarm: configStore.config.keepMicWarm,
        maxSeconds: { [configStore] in configStore.config.maxRecordingSeconds }
    )
    private lazy var monitor = ReadinessMonitor(probe: permissions, clock: SystemClock(),
                                                engine: EngineReadiness(engine))
    /// Built at launch, not on the first press, so the first dictation
    /// doesn't pay for the indicator, delivery and session setup.
    private var dictation: DictationSession?
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
        dictation = makeDictationSession()
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
        monitor.onTapNeeded = { [weak self] in self?.installHotkeys() }
    }

    private func requestPermissionsIfNeeded() {
        permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        if !permissions.isAccessibilityTrusted() {
            Log.info("Accessibility not yet granted; prompting user.")
            permissions.requestAccessibility()
        }
    }

    private func perform(_ action: ReadinessAction) {
        switch action {
        case .openAccessibilitySettings:
            permissions.requestAccessibility()
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
        Log.info("Engine: \(engine.model.engine.displayName). Model: \(engine.model.path) (language \(engine.model.language)); whisper auto-pick for this Mac: \(ModelCatalog.recommended(for: .current).id).")
        engine.load()
    }

    private func resolvedModel() -> ModelSpec {
        let selected = ModelSelection.select(configStore.config, presentFilenames: ModelSelection.presentFilenames())
        if selected.note != loggedFallback, let note = selected.note { Log.info(note) }
        loggedFallback = selected.note
        return selected.spec
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
        if let notice = ModelHints.notice(for: status, engine: readiness) {
            Log.error(notice.log)
            Notifier.notify(title: notice.title, body: notice.body)
        }
        if status == .ready { Log.info("Transcription model loaded: \(readiness.modelPath)") }
        monitor.engineChanged(readiness)
    }

    // MARK: - Dictation & hotkeys

    /// The dictation flow over the live mic, engine, paste and indicator.
    /// Settings are read live, so a change applies to the next recording; a
    /// press only starts one when readiness allows (re-checked per press,
    /// without installing a tap from inside the press). The session holds the
    /// monitor, so the gate can't outlive it and fail open.
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
            readiness: monitor.currentStatus
        )
    }

    /// (Re)installs the hotkey tap from the current config and reports the
    /// outcome to the monitor, which retries a failure with backoff. Only the
    /// monitor calls this (`onTapNeeded`).
    private func installHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        let config = configStore.config
        let manager = HotkeyManager(hold: config.hold, toggle: config.toggle, cancelKeyCode: config.cancelKeyCode)
        manager.onHoldStart = { [weak self] in self?.dictation?.handle(.holdDown) }
        manager.onHoldStop = { [weak self] in self?.dictation?.handle(.holdUp) }
        manager.onTogglePress = { [weak self] in self?.dictation?.handle(.toggle) }
        manager.onCancel = { [weak self] in self?.dictation?.handle(.cancel) }
        let started = manager.start()
        if started { hotkeys = manager }
        monitor.hotkeyTapChanged(started ? .installed : .failed)
    }

    /// The Settings recorder is capturing keys: take the tap down, and keep
    /// the monitor from putting it back until `monitor.resumeHotkeys()`.
    private func pauseHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        monitor.pauseHotkeys()
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
                    // swallow the chosen key; resuming reinstalls it from the
                    // (possibly rebound) config.
                    pauseHotkeys: { [weak self] in self?.pauseHotkeys() },
                    reloadHotkeys: { [weak self] in self?.monitor.resumeHotkeys() },
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
