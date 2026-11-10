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
/// - Whenever Accessibility is granted and the tap isn't installed, a poll
///   asks for it (`onTapNeeded`): the first install, a retry after a failed
///   one, and a reinstall after a revoke — while Accessibility is denied, any
///   tap is presumed dead.
/// - A failing tap (e.g. stale TCC after a re-sign: Accessibility reads
///   granted, the tap won't install) is retried with backoff — `pollInterval`,
///   then doubling, capped at `maxTapRetryInterval` — and logged once per
///   streak. A success or an Accessibility change resets it.
/// - While the hotkeys are paused (the Settings recorder captures keys) no tap
///   is requested; `resumeHotkeys()` reinstalls it at once.
/// - `currentStatus()` is for a hotkey press: it re-reads the permissions but
///   never installs the tap from inside the press (the tap's own callback);
///   a needed install runs on the next run-loop turn.
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
    /// `hotkeyTapChanged`. Called from a poll, never from `currentStatus()`.
    var onTapNeeded: (() -> Void)?

    private(set) var inputs: ReadinessInputs
    var status: AppStatus { AppReadiness.status(for: inputs) }

    private let probe: PermissionProbe
    private let clock: Clock
    private let pollInterval: TimeInterval
    private let readyPollInterval: TimeInterval
    private let maxTapRetryInterval: TimeInterval
    private let log: (String) -> Void

    private var isRunning = false
    private var timer: ClockTimer?
    private var timerDue: TimeInterval?
    private var lastStatus: AppStatus?
    private var lastInputs: ReadinessInputs?
    private var hasBeenReady = false
    private var isRequestingTap = false
    private var isPaused = false
    /// Failed installs in the current streak, and when the next may be tried.
    private var tapFailures = 0
    private var nextTapAttempt: TimeInterval?

    init(probe: PermissionProbe, clock: Clock, engine: EngineReadiness,
         pollInterval: TimeInterval = 2, readyPollInterval: TimeInterval = 10,
         maxTapRetryInterval: TimeInterval = 60,
         log: @escaping (String) -> Void = { Log.error($0) }) {
        self.probe = probe
        self.clock = clock
        self.pollInterval = pollInterval
        self.readyPollInterval = readyPollInterval
        self.maxTapRetryInterval = maxTapRetryInterval
        self.log = log
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

    /// The status for a hotkey press: permissions re-read and published, any
    /// tap install deferred to the next run-loop turn. Before `start()` it's
    /// the initial, not-ready status.
    func currentStatus() -> AppStatus {
        if isRunning { poll(installingTap: false) }
        return status
    }

    func engineChanged(_ engine: EngineReadiness) {
        inputs.engine = engine
        publish()
    }

    func hotkeyTapChanged(_ health: HotkeyTapHealth) {
        inputs.hotkeyTap = health
        switch health {
        case .failed:
            tapFailures += 1
            if tapFailures == 1 {
                log("Couldn't create the hotkey event tap; retrying with backoff. Re-granting Accessibility usually fixes it.")
            }
            let delay = min(pollInterval * pow(2, Double(tapFailures - 1)), maxTapRetryInterval)
            nextTapAttempt = clock.now + delay
        case .installed:
            if tapFailures > 0 { Log.info("Hotkey event tap installed after \(tapFailures) failed attempt(s).") }
            resetBackoff()
        case .notInstalled:
            break
        }
        publish()
    }

    /// The Settings recorder took the tap down to capture keys: request none
    /// until `resumeHotkeys()`. The status is left alone.
    func pauseHotkeys() {
        isPaused = true
    }

    /// Ends a pause (if any) and reinstalls the tap now, from the current
    /// config — also how a rebind is applied.
    func resumeHotkeys() {
        isPaused = false
        resetBackoff()
        if inputs.hotkeyTap == .installed { inputs.hotkeyTap = .notInstalled }
        recheck()
    }

    // MARK: - Polling

    private func poll(installingTap: Bool = true) {
        cancelTimer()
        let accessibility = probe.accessibility
        if accessibility != inputs.accessibility { resetBackoff() }
        inputs.accessibility = accessibility
        inputs.microphone = probe.microphone
        if inputs.accessibility == .denied { inputs.hotkeyTap = .notInstalled }

        if tapNeeded {
            if installingTap {
                // Before publishing, so a successful (synchronous) install goes
                // straight to ready without a "Starting hotkeys…" blip.
                isRequestingTap = true
                onTapNeeded?()
                isRequestingTap = false
            } else {
                schedule(after: 0)
            }
        }
        publish()
    }

    private var tapNeeded: Bool {
        guard !isPaused, !isRequestingTap, inputs.accessibility == .granted,
              inputs.hotkeyTap != .installed else { return false }
        return nextTapAttempt.map { clock.now >= $0 } ?? true
    }

    private func resetBackoff() {
        tapFailures = 0
        nextTapAttempt = nil
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
        schedule(after: status == .ready ? readyPollInterval : pollInterval)
    }

    /// One poll pending at a time: an earlier one already pending is kept
    /// (e.g. a deferred tap install), a later one is brought forward.
    private func schedule(after interval: TimeInterval) {
        guard isRunning else { return }
        let due = clock.now + interval
        if timer != nil, let timerDue, timerDue <= due { return }
        cancelTimer()
        timerDue = due
        timer = clock.schedule(after: interval) { [weak self] in self?.poll() }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerDue = nil
    }
}
