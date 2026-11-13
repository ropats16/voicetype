import Foundation

/// Runs async work to completion from synchronous code, with a deadline. For
/// adapters over async-only APIs, whose sync calls come on the engine's serial
/// queue: the work runs detached on the cooperative pool and never needs the
/// main thread, so blocking the caller can't deadlock it. Don't call it from
/// the cooperative pool itself (an async context), which it would starve.
enum BlockingAsync {
    struct TimedOut: Error {}

    /// `work`'s result, or its error. Past `timeout` seconds the work is
    /// cancelled and `TimedOut` thrown without waiting for it to wind down.
    static func run<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            do { outcome.set(.success(try await work())) } catch { outcome.set(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw TimedOut()
        }
        return try outcome.get()
    }

    private final class Outcome<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?

        func set(_ result: Result<T, Error>) { lock.withLock { self.result = result } }
        func get() throws -> T { try lock.withLock { result! }.get() }
    }
}
