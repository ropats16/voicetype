import Foundation

/// Apple's on-device SpeechAnalyzer (macOS 26) as an `EngineDescriptor`. No
/// model files: macOS downloads and manages one model per locale, so the
/// "model" is the language (`AppleSpeechLocale`), presence is its asset state
/// (`AppleSpeechAssets`), and the download is Settings' Download button.
struct AppleSpeechEngine: EngineDescriptor {
    let kind = EngineKind.appleSpeech

    /// Whether this Mac's hardware runs `SpeechTranscriber`; asked only on
    /// macOS 26+. Injectable for tests.
    var transcriberAvailable: () -> Bool = AppleSpeechAvailability.transcriberAvailableOnThisMac
    /// The asset state for a language. Injectable for tests; the live one
    /// asks the OS (a quick XPC round trip) and blocks for it, at most 2 s.
    var assetState: (String) -> AppleSpeechAssetState = AppleSpeechEngine.liveAssetState

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        guard environment.isAtLeast(macOS: 26) else { return .unavailable(reason: "\(kind.displayName) needs macOS 26") }
        guard transcriberAvailable() else { return .unavailable(reason: "this Mac doesn't support \(kind.displayName)") }
        return .available
    }

    /// The languages SpeechTranscriber had on macOS 26.x (it has no sync
    /// query); one the OS lacks still fails the load with a clear reason.
    /// "auto" means the Mac's own language (`AppleSpeechLocale`), as the
    /// transcriber can't detect one.
    let supportedLanguages: Set<String>? = [ModelSpec.autoDetect, "en", "fr", "de", "it", "es", "pt",
                                            "zh", "ja", "ko", "yue"]

    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        .appleSpeech(language: context.language)
    }

    /// Installed (or unsupported, so the load fails saying so) → present; not
    /// downloaded or downloading → `.missing`, with the download hint.
    func isPresent(_ spec: ModelSpec) -> Bool {
        switch assetState(spec.language) {
        case .installed, .unsupported: return true
        case .notInstalled, .downloading: return false
        }
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        .instructions("Apple's speech model for this language isn't downloaded. Open Settings › Model to download it.")
    }

    /// No model to name: `--model` is ignored, `--language` picks the model.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        .appleSpeech(language: language.isEmpty ? ModelSpec.autoDetect : language)
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.appleSpeechAdapter()
    }

    let acknowledgement = """
        Apple Speech framework (SpeechAnalyzer, SpeechTranscriber) and its on-device speech models, \
        by Apple, part of macOS.
        """

    static func liveAssetState(_ language: String) -> AppleSpeechAssetState {
        guard #available(macOS 26, *), AppleSpeechAvailability.isAvailable() else { return .unsupported }
        // On timeout, let the load try: the adapter then fails with the real reason.
        return (try? BlockingAsync.run(timeout: 2) { await AppleSpeechAssets.state(for: language) }) ?? .installed
    }
}
