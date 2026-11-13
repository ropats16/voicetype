import XCTest
@testable import VoiceType

/// The Automatic engine policy (#15): which engine a Mac runs when
/// `config.json`'s `engine` is "auto", from the Mac, the OS, the language and
/// which engines' models are installed. One table, the decision in
/// `plans/bench-results/15/README.md`.
final class EnginePolicyTests: XCTestCase {

    /// The real engines (their real language sets), with Apple Speech's
    /// hardware probe pinned so the table doesn't depend on this Mac.
    private let engines = EngineRegistry([
        WhisperEngine(), WhisperKitEngine(), ParakeetEngine(),
        AppleSpeechEngine(transcriberAvailable: { true }, assetState: { _ in .installed }),
    ])

    private let all: Set<EngineKind> = [.whisper, .whisperKit, .parakeet, .appleSpeech]

    private func pick(_ language: String, on environment: EngineEnvironment,
                      installed: Set<EngineKind>, failed: Set<EngineKind> = []) -> EnginePolicy.Pick {
        EnginePolicy.automatic(language: language, environment: environment, installed: installed,
                               failed: failed, engines: engines)
    }

    func testTheDefaultEngineTable() {
        let tahoe = EngineEnvironment.mac(26, gib: 8)
        let sequoia = EngineEnvironment.mac(15, gib: 8)
        let intel = EngineEnvironment.mac(26, appleSilicon: false, gib: 16)

        let rows: [(String, EngineEnvironment, Set<EngineKind>, Set<EngineKind>, EngineKind, String?, UInt)] = [
            // Turbo's languages with its model: Turbo, on any Apple Silicon macOS.
            ("en", tahoe, all, [], .parakeet, nil, #line),
            ("de", sequoia, [.whisper, .parakeet], [], .parakeet, nil, #line),
            // Not downloaded: Apple Speech if it takes the language and its model is there, else whisper.
            ("en", tahoe, [.whisper, .appleSpeech, .whisperKit], [], .appleSpeech, "Turbo isn't downloaded", #line),
            ("en", sequoia, [.whisper, .appleSpeech, .whisperKit], [], .whisper, "Turbo isn't downloaded", #line),
            ("en", tahoe, [.whisper, .whisperKit], [], .whisper, "Turbo isn't downloaded", #line),
            // Failed to load this session: skipped like a missing model.
            ("en", tahoe, all, [.parakeet], .appleSpeech, "Turbo failed to load", #line),
            ("en", tahoe, all, [.parakeet, .appleSpeech], .whisper, "Turbo failed to load", #line),
            // Other explicit languages: Apple Speech (macOS 26, supported, installed), else whisper.
            ("ja", tahoe, all, [], .appleSpeech, "Turbo doesn't support Japanese", #line),
            ("ja", tahoe, [.whisper, .parakeet], [], .whisper, "Turbo doesn't support Japanese", #line),
            ("ja", sequoia, all, [], .whisper, "Turbo doesn't support Japanese", #line),
            ("hi", tahoe, all, [], .whisper, "Turbo doesn't support Hindi", #line),
            // Auto-detect: whisper, whatever is installed.
            ("auto", tahoe, all, [], .whisper, "Turbo doesn't detect the language", #line),
            // Intel: whisper.
            ("en", intel, all, [], .whisper, "Turbo needs Apple Silicon", #line),
        ]
        for (language, environment, installed, failed, kind, reason, line) in rows {
            let result = pick(language, on: environment, installed: installed, failed: failed)
            XCTAssertEqual(result.kind, kind, "\(language) on macOS \(environment.macOSMajor)", line: line)
            XCTAssertEqual(result.reason, reason, line: line)
        }
    }

    func testWhisperKitIsNeverTheDefault() {
        for language in ["en", "ja", "auto", "hi"] {
            for installed in [[.whisperKit], [.whisper, .whisperKit], all] as [Set<EngineKind>] {
                XCTAssertNotEqual(pick(language, on: .mac(26), installed: installed).kind, .whisperKit)
            }
        }
    }

    func testWhisperIsPickedEvenWithNothingDownloaded() {
        // whisper's own Automatic then names the model to download.
        XCTAssertEqual(pick("en", on: .mac(26), installed: []).kind, .whisper)
    }

    func testAnEngineMissingFromTheBuildIsSkipped() {
        let whisperOnly = EngineRegistry([WhisperEngine()])
        let result = EnginePolicy.automatic(language: "en", environment: .mac(26), installed: all,
                                            engines: whisperOnly)
        XCTAssertEqual(result, EnginePolicy.Pick(kind: .whisper, reason: "Turbo isn't in this build"))
    }
}
