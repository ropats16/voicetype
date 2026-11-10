@testable import VoiceType
import Foundation

/// A `Clock` that only moves when told to; shared by every test that
/// schedules time (dictation, delivery, readiness).
final class ManualClock: Clock {
    final class Pending: ClockTimer {
        let due: TimeInterval
        let action: () -> Void
        var isCancelled = false
        var hasFired = false
        init(due: TimeInterval, action: @escaping () -> Void) { self.due = due; self.action = action }
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 1_000
    private(set) var timers: [Pending] = []

    /// Timers neither fired nor cancelled.
    var live: [Pending] { timers.filter { !$0.isCancelled && !$0.hasFired } }

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> ClockTimer {
        let timer = Pending(due: now + seconds, action: action)
        timers.append(timer)
        return timer
    }

    /// Moves time on, firing every live timer that comes due.
    func advance(by seconds: TimeInterval) {
        now += seconds
        for timer in timers where !timer.isCancelled && !timer.hasFired && timer.due <= now {
            timer.hasFired = true
            timer.action()
        }
    }
}
