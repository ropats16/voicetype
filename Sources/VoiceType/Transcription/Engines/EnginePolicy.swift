import Foundation

/// Which engine Automatic (`config.json`'s `engine: "auto"`, the default)
/// runs: the benchmark decision of #15 (`plans/bench-results/15/README.md`),
/// for dictation and, later, meetings alike. First match wins:
///
/// 1. Intel → whisper.cpp.
/// 2. Auto-detect language → whisper.cpp (Turbo and Apple Speech can't detect).
/// 3. Turbo (Parakeet) takes the language and its model is installed → Turbo.
/// 4. Apple Speech can run here (macOS 26), takes the language and its model
///    is installed → Apple Speech.
/// 5. Otherwise → whisper.cpp, whose own Automatic picks a model by RAM.
///
/// WhisperKit is never picked. Nothing is ever downloaded: an engine counts
/// only once its model is installed, and one that failed to load is skipped
/// like a missing one. Pure: the caller states what's installed.
enum EnginePolicy {

    struct Pick: Equatable {
        let kind: EngineKind
        /// Why it isn't Turbo, e.g. "Turbo isn't downloaded"; nil when it is.
        let reason: String?
    }

    /// `installed`: engines whose model (the one their own pick resolves to)
    /// is installed. `failed`: engines whose model failed to load (skipped).
    static func automatic(language: String, environment: EngineEnvironment, installed: Set<EngineKind>,
                          failed: Set<EngineKind> = [], engines: EngineRegistry = .shared) -> Pick {
        automatic(language: language, environment: environment, isInstalled: installed.contains,
                  failed: failed, engines: engines)
    }

    /// The same, asking `isInstalled` only about an engine that could
    /// otherwise be picked (so a caller need only check those).
    static func automatic(language: String, environment: EngineEnvironment, isInstalled: (EngineKind) -> Bool,
                          failed: Set<EngineKind> = [], engines: EngineRegistry = .shared) -> Pick {
        let turbo = EngineKind.parakeet
        func usable(_ kind: EngineKind) -> Bool {
            guard let descriptor = engines.descriptor(for: kind) else { return false }
            return descriptor.availability(in: environment) == .available && descriptor.supports(language: language)
                && !failed.contains(kind) && isInstalled(kind)
        }

        guard environment.hardware.isAppleSilicon else {
            return Pick(kind: .whisper, reason: "\(turbo.shortName) needs Apple Silicon")
        }
        guard language != ModelSpec.autoDetect else {
            return Pick(kind: .whisper, reason: "\(turbo.shortName) doesn't detect the language")
        }
        if usable(turbo) { return Pick(kind: turbo, reason: nil) }

        let whyNotTurbo = reason(turbo, isn: language, environment: environment, failed: failed, engines: engines)
        if usable(.appleSpeech) { return Pick(kind: .appleSpeech, reason: whyNotTurbo) }
        return Pick(kind: .whisper, reason: whyNotTurbo)
    }

    /// Why `kind` isn't usable, in the order a user would fix it.
    private static func reason(_ kind: EngineKind, isn language: String, environment: EngineEnvironment,
                               failed: Set<EngineKind>, engines: EngineRegistry) -> String {
        guard let descriptor = engines.descriptor(for: kind) else { return "\(kind.shortName) isn't in this build" }
        if case .unavailable(let reason) = descriptor.availability(in: environment) { return reason }
        if !descriptor.supports(language: language) {
            return "\(kind.shortName) doesn't support \(EngineRegistry.languageName(language))"
        }
        if failed.contains(kind) { return "\(kind.shortName) failed to load" }
        return "\(kind.shortName) isn't downloaded"
    }
}
