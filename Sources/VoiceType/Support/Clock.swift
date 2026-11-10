import Foundation

// Time as a port: the dictation session (start time, max-duration stop),
// delivery (clipboard restore) and readiness (polling, tap retry backoff) read
// it through `Clock`, so tests drive them with a manual one.
//
// Shadows the standard library's `Clock` inside this module.

/// A scheduled one-shot callback that hasn't fired yet.
protocol ClockTimer: AnyObject {
    /// Stops it firing. Safe to call after it fired or more than once.
    func cancel()
}

/// Monotonic time and one-shot timers on main.
protocol Clock: AnyObject {
    /// Monotonic seconds (e.g. system uptime).
    var now: TimeInterval { get }
    /// Calls `action` once on main after `seconds`, unless cancelled first.
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> ClockTimer
}

/// The live clock: system uptime and a main run-loop `Timer`.
final class SystemClock: Clock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// In the common modes, not just default: while a menu is open (the
    /// menu-bar menu) main runs in event-tracking mode, and a default-mode
    /// timer — a clipboard restore, the max-duration stop — would wait for it
    /// to close.
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> ClockTimer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopTimer(timer)
    }

    private final class RunLoopTimer: ClockTimer {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }
}
