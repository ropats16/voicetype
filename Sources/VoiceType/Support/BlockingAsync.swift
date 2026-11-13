import Foundation

/// Runs async work to completion from synchronous code, with a deadline: for
/// adapters over async-only APIs (on the engine's serial queue) and the odd
/// sync query of an async OS API. It blocks the calling thread, so never call
/// it on main (it would stall the UI) or from the cooperative pool itself (an
/// async context, which it would starve). The work runs detached on the
/// cooperative pool and never needs the main thread, so it can't deadlock.
///
/// An adapter calls through its `Bridge` instead, so work it gave up on can't
/// overlap the next call.
enum BlockingAsync {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "The speech engine didn't finish in time." }
    }

    /// A `Bridge` refused a call: work it gave up on (`TimedOut`) is still running.
    struct StillBusy: LocalizedError {
        let name: String
        var errorDescription: String? {
            "\(name) is still finishing work that timed out. Try again in a moment, or restart VoiceType."
        }
    }

    /// `work`'s result, or its error. Past `timeout` seconds the work is
    /// cancelled and `TimedOut` thrown without waiting for it to wind down —
    /// cancellation is cooperative, so it may run on for a while.
    static func run<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) throws -> T {
        try run(timeout: timeout, work, onAbandon: {}, whenAbandonedEnds: {})
    }

    /// One adapter's (or engine kind's) way into its async engine. Async
    /// engines don't stop when told to: after a timeout the abandoned work may
    /// keep using the engine (WhisperKit's non-`Sendable` pipeline, a model
    /// still loading), so until it ends every call throws `StillBusy` rather
    /// than run alongside it — no data race, no second model loading. The
    /// engine's queue stays free; once the work ends, calls run again.
    /// Calls must not overlap (the engine's queue serializes them).
    final class Bridge: @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var abandoned = 0

        /// `name` is the engine, as `StillBusy` names it.
        init(name: String) { self.name = name }

        /// Whether abandoned work is still running.
        var isBusy: Bool { lock.withLock { abandoned > 0 } }

        func run<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) throws -> T {
            guard !isBusy else { throw StillBusy(name: name) }
            return try BlockingAsync.run(timeout: timeout, work,
                                         onAbandon: { [self] in lock.withLock { abandoned += 1 } },
                                         whenAbandonedEnds: { [self] in lock.withLock { abandoned -= 1 } })
        }
    }

    /// `onAbandon` runs (on the caller) when the deadline passes with the work
    /// unfinished, always before `whenAbandonedEnds` (on the work's task).
    private static func run<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T,
                               onAbandon: () -> Void,
                               whenAbandonedEnds: @escaping @Sendable () -> Void) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            if outcome.finish(result) { whenAbandonedEnds() }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success || !outcome.abandonIfRunning(onAbandon) else {
            task.cancel()
            throw TimedOut()
        }
        return try outcome.get()
    }

    private final class Outcome<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var abandoned = false

        /// Stores the result; true if the caller had already given up on it.
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.withLock { self.result = result; return abandoned }
        }

        /// Gives up on the work unless it finished just now; true if it did give up.
        func abandonIfRunning(_ onAbandon: () -> Void) -> Bool {
            lock.withLock {
                guard result == nil else { return false }
                onAbandon()
                abandoned = true
                return true
            }
        }

        func get() throws -> T { try lock.withLock { result! }.get() }
    }
}
