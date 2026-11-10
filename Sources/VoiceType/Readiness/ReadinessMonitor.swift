import Foundation

/// Keeps the app's `AppStatus` current and owns the retry/re-arm policy.
///
/// - Permissions are polled through the probe; engine status and tap health
///   are pushed in (`engineChanged`, `hotkeyTapChanged`).
/// - Polling never stops: every `pollInterval` while not ready (so a grant in
///   System Settings shows up within seconds), every `readyPollInterval` while
///   ready (so a revoked permission is noticed without a user action). Both
///   probe reads are cheap, and nothing is emitted unless something changed.
///   `recheck()` polls at once (e.g. after the mic prompt is answered).
/// - Whenever Accessibility is granted and the tap isn't installed, each poll
///   asks for it (`onTapNeeded`): the first install, a retry after a failed
///   one, and a reinstall after a revoke — while Accessibility is denied, any
///   tap is presumed dead.
/// - `onChange` fires only when the status changes, `onInputsChange` only
///   when an input does, and `onBecameReady` once per transition into ready
///   (`isFirst` for the first since launch).
///
/// Main thread only. Nothing is emitted before `start()`.
final class ReadinessMonitor {
    var onChange: ((AppStatus) -> Void)?
    var onInputsChange: ((ReadinessInputs) -> Void)?
    var onBecameReady: ((_ isFirst: Bool) -> Void)?
    /// Install (or reinstall) the hotkey tap, then report the outcome with
    /// `hotkeyTapChanged`. Called from a poll.
    var onTapNeeded: (() -> Void)?

    private(set) var inputs: ReadinessInputs
    var status: AppStatus { AppReadiness.status(for: inputs) }

    private let probe: PermissionProbe
    private let clock: DictationClock
    private let pollInterval: TimeInterval
    private let readyPollInterval: TimeInterval

    private var isRunning = false
    private var timer: DictationTimer?
    private var timerInterval: TimeInterval?
    private var lastStatus: AppStatus?
    private var lastInputs: ReadinessInputs?
    private var hasBeenReady = false
    private var isRequestingTap = false

    init(probe: PermissionProbe, clock: DictationClock, engine: EngineReadiness,
         pollInterval: TimeInterval = 2, readyPollInterval: TimeInterval = 10) {
        self.probe = probe
        self.clock = clock
        self.pollInterval = pollInterval
        self.readyPollInterval = readyPollInterval
        self.inputs = ReadinessInputs(accessibility: .denied, microphone: .notDetermined,
                                      engine: engine, hotkeyTap: .notInstalled)
    }

    /// Polls now (emitting the first status) and keeps polling.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        poll()
    }

    func stop() {
        isRunning = false
        cancelTimer()
    }

    /// Polls now instead of at the next tick.
    func recheck() {
        guard isRunning else { return }
        poll()
    }

    func engineChanged(_ engine: EngineReadiness) {
        inputs.engine = engine
        publish()
    }

    func hotkeyTapChanged(_ health: HotkeyTapHealth) {
        inputs.hotkeyTap = health
        publish()
    }

    // MARK: - Polling

    private func poll() {
        cancelTimer()
        inputs.accessibility = probe.accessibility
        inputs.microphone = probe.microphone
        if inputs.accessibility == .denied { inputs.hotkeyTap = .notInstalled }

        // Before publishing, so a successful (synchronous) install goes
        // straight to ready without a "Starting hotkeys…" blip.
        if inputs.accessibility == .granted, inputs.hotkeyTap != .installed, !isRequestingTap {
            isRequestingTap = true
            onTapNeeded?()
            isRequestingTap = false
        }
        publish()
    }

    /// Emits what changed, then makes sure the next poll is due at the
    /// interval the status calls for.
    private func publish() {
        guard isRunning else { return }
        let inputs = inputs, status = status

        if inputs != lastInputs {
            lastInputs = inputs
            onInputsChange?(inputs)
        }
        if status != lastStatus {
            let wasReady = lastStatus == .ready
            lastStatus = status
            onChange?(status)
            if status == .ready && !wasReady {
                let isFirst = !hasBeenReady
                hasBeenReady = true
                onBecameReady?(isFirst)
            }
        }
        schedule()
    }

    private func schedule() {
        guard isRunning else { return }
        let interval = status == .ready ? readyPollInterval : pollInterval
        if timer != nil, timerInterval == interval { return }
        cancelTimer()
        timerInterval = interval
        timer = clock.schedule(after: interval) { [weak self] in self?.poll() }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerInterval = nil
    }
}
