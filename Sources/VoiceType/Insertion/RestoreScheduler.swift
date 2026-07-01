/// Pure, unit-testable clipboard-restore coordination split out of
/// `TextInserter` so the pending/superseding decision can be exercised with
/// synthetic call sequences — no real `NSPasteboard` or `Timer` required.
/// Mirrors how `Sources/VoiceType/Hotkeys/HotkeyMatcher.swift` extracts pure
/// edge-detection logic out of `HotkeyManager` for the same reason.
///
/// A burst of overlapping `insert()` calls (e.g. two dictations in quick
/// succession) must collapse to exactly one correct restore — of the
/// clipboard as it was *before the first insert in the burst* — after the
/// *last* insert's delay has elapsed. A generation counter tracks this: each
/// `beginInsert()` issues a new token and reports whether this call starts a
/// new burst (should capture a fresh origin snapshot) or joins one already in
/// flight (should reuse the prior origin). `restoreFired(_:)` reports whether
/// the firing token is still the most recently issued one; only that restore
/// should actually write to the pasteboard, and firing clears the pending
/// state so the next insert starts a fresh burst.
struct RestoreScheduler {
    /// Opaque handle for one scheduled restore, returned by `beginInsert()`
    /// and passed back to `restoreFired(_:)` when that restore's timer fires.
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    private var generation = 0
    private var pendingGeneration: Int?

    /// Call at the start of `insert(_:)`, before capturing the pasteboard.
    /// Returns whether the caller should capture a fresh origin snapshot
    /// (`true` iff no restore is currently pending, i.e. this insert starts a
    /// new burst) and the token to schedule the eventual restore under.
    mutating func beginInsert() -> (shouldCaptureOrigin: Bool, token: Token) {
        generation += 1
        let shouldCaptureOrigin = pendingGeneration == nil
        pendingGeneration = generation
        return (shouldCaptureOrigin, Token(generation: generation))
    }

    /// Call when a scheduled restore's timer fires. Returns whether `token`
    /// is still the most recently issued one — only then should the caller
    /// actually write the origin snapshot back to the pasteboard. A
    /// superseded (stale) token leaves the pending state untouched and
    /// returns `false`, so it performs no restore.
    mutating func restoreFired(_ token: Token) -> Bool {
        guard token.generation == pendingGeneration else { return false }
        pendingGeneration = nil
        return true
    }
}
