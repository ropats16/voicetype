import Foundation

/// Reloads Apple Speech once its missing model turns up. macOS may install it
/// outside Settings (the OS itself, or another app's download), and nothing
/// tells the engine, which would stay `.missing` until a restart. So while it
/// is, the app calls `check()` now and then (a timer, the menu opening, a
/// dictation press): one async asset query, and `reload` when it's installed.
/// Cheap otherwise: no query unless an Apple model is missing.
///
/// `@unchecked Sendable`: used, and its state touched, only on main; the
/// query's task only hops back there.
final class AppleSpeechModelWatch: @unchecked Sendable {
    private let assets: SpeechModelAssets
    private let missingModel: () -> ModelSpec?
    private let reload: () -> Void
    private var isChecking = false

    /// `missingModel` is the Apple Speech model the engine reports missing,
    /// else nil; `reload` re-applies the model settings (the engine retries).
    init(assets: SpeechModelAssets = LiveSpeechModelAssets(),
         missingModel: @escaping () -> ModelSpec?, reload: @escaping () -> Void) {
        self.assets = assets
        self.missingModel = missingModel
        self.reload = reload
    }

    func check() {
        guard !isChecking, let spec = missingModel() else { return }
        isChecking = true
        Task.detached { [assets] in
            let state = await assets.state(language: spec.language)
            DispatchQueue.main.async { [self] in
                isChecking = false
                // Stale if the engine moved on meanwhile.
                guard state == .installed, missingModel() == spec else { return }
                Log.info("Apple's speech model is now installed; loading it.")
                reload()
            }
        }
    }
}
