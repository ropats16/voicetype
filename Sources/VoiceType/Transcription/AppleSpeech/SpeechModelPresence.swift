import Foundation

/// Whether Apple Speech's model is installed, per language, as last asked.
/// Automatic (`EnginePolicy`) needs that answer on main, but the OS query is
/// async (an XPC round trip), so the app asks in the background with
/// `refresh` and re-resolves only when the answer changes. Never asked counts
/// as not installed: Automatic then picks another engine, never a download.
///
/// `@unchecked Sendable`: used, and its state touched, only on main; the
/// query's task only hops back there.
final class SpeechModelPresence: @unchecked Sendable {
    private let assets: SpeechModelAssets
    private var installed: [String: Bool] = [:]

    init(assets: SpeechModelAssets = LiveSpeechModelAssets()) {
        self.assets = assets
    }

    /// The last answer for `language` (an ISO code); false if never asked.
    func isInstalled(language: String) -> Bool {
        installed[language] ?? false
    }

    /// Whether `language` was ever asked about.
    func isKnown(language: String) -> Bool {
        installed[language] != nil
    }

    /// Asks the OS about `language`; `completion` runs on main with whether
    /// the answer differs from the last one.
    func refresh(language: String, completion: @escaping (_ changed: Bool) -> Void = { _ in }) {
        Task.detached { [assets] in
            let isInstalled = await assets.state(language: language) == .installed
            DispatchQueue.main.async { [self] in
                let changed = isInstalled != self.isInstalled(language: language)
                installed[language] = isInstalled
                completion(changed)
            }
        }
    }
}
