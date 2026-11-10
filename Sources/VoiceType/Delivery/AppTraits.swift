import ApplicationServices
import Foundation

/// What the focus probe remembers about one running app process: whether
/// it's Chromium-hosted, and where the `AXManualAccessibility` opt-in stands.
/// Pure: `AXFocusProbe` gathers the facts and sends the opt-in.
struct AppTraits: Equatable {
    /// The process's launch date, telling a reused pid from the process these
    /// traits were made for. `nil` when the system doesn't know it.
    let launchDate: Date?
    let isChromiumHosted: Bool
    private(set) var optIn: OptIn = .due

    enum OptIn: Equatable {
        /// Send it on the next probe.
        case due
        /// The app timed out; not before this (`now` seconds).
        case retryAfter(TimeInterval)
        /// Landed, or the app has no such attribute: never again.
        case settled
    }

    /// A timed-out opt-in costs the full AX messaging timeout (0.25 s) on
    /// main. Retrying on every delivery would charge a perpetually hung (or
    /// never-answering) app that on each dictation; giving up after a few
    /// tries would leave an Electron app that was merely busy at launch
    /// without its AX tree for good. Every 30 s bounds the cost to 0.25 s per
    /// 30 s while still recovering the app once it answers. Not opting in only
    /// costs precision anyway: no focused element → `.unknown` → pasted.
    static let timedOutRetryInterval: TimeInterval = 30

    init(launchDate: Date?, isChromiumHosted: Bool) {
        self.launchDate = launchDate
        self.isChromiumHosted = isChromiumHosted
    }

    func needsOptIn(now: TimeInterval) -> Bool {
        switch optIn {
        case .due: return true
        case .retryAfter(let time): return now >= time
        case .settled: return false
        }
    }

    /// Records the result of setting `AXManualAccessibility`.
    /// - `.success`: Chromium opted in (it lasts for the process's lifetime);
    ///   `.attributeUnsupported`: a native app without it. Either way, done.
    /// - `.cannotComplete`: timed out (hung or busy): back off.
    /// - Anything else fails fast — notably `.apiDisabled` before the user
    ///   grants Accessibility — so it's retried on the next probe at no cost.
    mutating func recordOptIn(_ result: AXError, now: TimeInterval) {
        switch result {
        case .success, .attributeUnsupported: optIn = .settled
        case .cannotComplete: optIn = .retryAfter(now + Self.timedOutRetryInterval)
        default: optIn = .due
        }
    }

    /// Whether an app bundle whose `Contents/Frameworks` holds `frameworks` is
    /// Chromium-hosted. Electron ships `Electron Framework.framework`, CEF apps
    /// `Chromium Embedded Framework.framework`, and Chrome-family browsers
    /// `<Browser> Framework.framework` (Google Chrome, Microsoft Edge, Brave,
    /// …) — all the Chromium "<name> Framework.framework" convention. A false
    /// positive only costs a later restore (still changeCount-guarded).
    static func isChromiumHosted(frameworks: [String]) -> Bool {
        frameworks.contains { $0.hasSuffix(" Framework.framework") }
    }
}

/// `AppTraits` per running process. Entries are evicted when their process
/// quits, so the cache is bounded by the apps running; a pid reused by a new
/// process (different launch date) never sees the old process's traits.
struct AppTraitsCache {
    private var byPID: [pid_t: AppTraits] = [:]

    var count: Int { byPID.count }

    /// The traits stored for `pid`, unless they belong to an earlier process
    /// that had the same pid.
    func traits(pid: pid_t, launchDate: Date?) -> AppTraits? {
        guard let traits = byPID[pid], traits.launchDate == launchDate else { return nil }
        return traits
    }

    mutating func store(_ traits: AppTraits, pid: pid_t) { byPID[pid] = traits }

    mutating func evict(pid: pid_t) { byPID[pid] = nil }
}
