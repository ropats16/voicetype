import XCTest
@testable import VoiceType

/// The Apple SpeechAnalyzer engine's pure seams (#14): the OS gate, language →
/// locale, asset state, and results → segments. None need macOS 26.
final class AppleSpeechMappingTests: XCTestCase {

    // MARK: - OS gate

    func testOfferedFromMacOS26Only() {
        let os = { (major: Int, minor: Int) in OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0) }
        XCTAssertFalse(AppleSpeechAvailability.isOSSupported(os(14, 2)))
        XCTAssertFalse(AppleSpeechAvailability.isOSSupported(os(15, 7)))
        XCTAssertTrue(AppleSpeechAvailability.isOSSupported(os(26, 0)))
        XCTAssertTrue(AppleSpeechAvailability.isOSSupported(os(27, 1)))
    }

    func testHiddenWhenTheHardwareCantRunTheTranscriber() {
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        XCTAssertTrue(AppleSpeechAvailability.isAvailable(os: tahoe, transcriberAvailable: { true }))
        XCTAssertFalse(AppleSpeechAvailability.isAvailable(os: tahoe, transcriberAvailable: { false }))
        XCTAssertFalse(AppleSpeechAvailability.isAvailable(os: sonoma, transcriberAvailable: {
            XCTFail("The transcriber must not be asked below macOS 26"); return true
        }))
    }

    // MARK: - Language → locale

    /// What macOS 26.x's SpeechTranscriber supported on an M-series Mac.
    private let supported = ["fr_FR", "fr_CH", "fr_CA", "fr_BE", "ko_KR", "pt_BR", "pt_PT", "de_AT", "de_CH",
                             "de_DE", "it_IT", "it_CH", "zh_CN", "zh_TW", "es_CL", "es_ES", "es_US", "es_MX",
                             "en_ZA", "en_CA", "en_SG", "en_IN", "en_NZ", "en_GB", "en_AU", "en_US", "en_IE",
                             "yue_CN", "zh_HK", "ja_JP"].map(Locale.init(identifier:))

    private func resolve(_ language: String, system: String = "en_US", preferred: [String] = ["en-US"]) -> String? {
        AppleSpeechLocale.resolve(language: language, supported: supported,
                                  systemLocale: Locale(identifier: system), preferredLanguages: preferred)?.identifier
    }

    func testABareLanguageCodePicksItsMainRegion() {
        XCTAssertEqual(resolve("en", system: "en_IN"), "en_US")
        XCTAssertEqual(resolve("de"), "de_DE")
        XCTAssertEqual(resolve("fr"), "fr_FR")
        XCTAssertEqual(resolve("es"), "es_ES")
        XCTAssertEqual(resolve("pt"), "pt_BR")
        XCTAssertEqual(resolve("ja"), "ja_JP")
    }

    func testARegionalCodeIsKeptWhenSupported() {
        XCTAssertEqual(resolve("en-GB"), "en_GB")
        XCTAssertEqual(resolve("pt_PT"), "pt_PT")
    }

    func testARegionTheTranscriberLacksFallsBackToTheLanguage() {
        XCTAssertEqual(resolve("de-LU"), "de_DE")
        XCTAssertEqual(resolve("en-PH"), "en_US")
    }

    func testAnUnsupportedLanguageResolvesToNothing() {
        XCTAssertNil(resolve("hi"))
        XCTAssertNil(resolve("nl"))
    }

    /// The transcriber can't detect the language, so "auto" means the Mac's
    /// own: its region first, then the preferred languages, then en-US.
    func testAutoUsesTheMacsLanguage() {
        XCTAssertEqual(resolve(ModelSpec.autoDetect, system: "en_IN", preferred: ["en-GB", "hi-IN"]), "en_IN")
        XCTAssertEqual(resolve(ModelSpec.autoDetect, system: "de_DE", preferred: ["de-DE"]), "de_DE")
        XCTAssertEqual(resolve(ModelSpec.autoDetect, system: "nl_NL", preferred: ["nl-NL", "fr-BE"]), "fr_BE")
        XCTAssertEqual(resolve(ModelSpec.autoDetect, system: "nl_NL", preferred: ["nl-NL"]), "en_US")
    }

    // MARK: - Asset state

    private func state(_ inventory: AppleSpeechAssetState.Inventory, onDisk: Bool = false,
                       installing: Double? = nil) -> AppleSpeechAssetState {
        AppleSpeechAssetState(inventory: inventory, installedOnMac: onDisk, installProgress: installing)
    }

    func testInventoryStatusesMapToAssetStates() {
        XCTAssertEqual(state(.unsupported), .unsupported)
        XCTAssertEqual(state(.supported), .notInstalled)
        XCTAssertEqual(state(.downloading), .downloading(progress: nil))
        XCTAssertEqual(state(.installed), .installed)
    }

    /// The inventory says `supported` for a model another app already
    /// downloaded until this app reserves it; it transcribes all the same.
    func testAModelAlreadyOnTheMacCountsAsInstalled() {
        XCTAssertEqual(state(.supported, onDisk: true), .installed)
    }

    func testAnInstallThisAppStartedReportsItsProgress() {
        XCTAssertEqual(state(.supported, installing: 0.4), .downloading(progress: 0.4))
        XCTAssertEqual(state(.downloading, installing: 0.7), .downloading(progress: 0.7))
        XCTAssertEqual(state(.installed, installing: 1), .installed)
    }

    func testOnlyAnInstalledModelCanTranscribe() {
        XCTAssertTrue(AppleSpeechAssetState.installed.canTranscribe)
        for other: AppleSpeechAssetState in [.unsupported, .notInstalled, .downloading(progress: 0.5)] {
            XCTAssertFalse(other.canTranscribe)
        }
    }

    // MARK: - Results → segments

    private typealias Piece = AppleSpeechSegments.Piece

    /// As the transcriber reported the JFK sample: the first result without a
    /// leading space, later ones with.
    func testSegmentsJoinLikeWhispers() {
        let segments = AppleSpeechSegments.segments(from: [
            Piece(text: "And so, my fellow Americans, ask not what your country can do for you.",
                  start: 0, end: 7.8, wordTimes: []),
            Piece(text: " Ask what you can do for your country.", start: 7.8, end: 10.5, wordTimes: []),
        ], clipSeconds: 11)
        XCTAssertEqual(segments.map(\.text), [" And so, my fellow Americans, ask not what your country can do for you.",
                                              " Ask what you can do for your country."])
        XCTAssertEqual(Transcript(segments: segments).text,
                       " And so, my fellow Americans, ask not what your country can do for you."
                       + " Ask what you can do for your country.")
    }

    func testTimesSpanTheWordsWhenTheyAreKnown() {
        let segments = AppleSpeechSegments.segments(from: [
            Piece(text: " Ask what you can.", start: 7.8, end: 10.5,
                  wordTimes: [(7.9, 8.4), (8.4, 8.76), (8.76, 9.0), (9.0, 9.24)]),
        ], clipSeconds: 11)
        XCTAssertEqual(segments, [Transcript.Segment(text: " Ask what you can.", start: 7.9, end: 9.24)])
    }

    func testTimesStayInTheClipAndInOrder() {
        let segments = AppleSpeechSegments.segments(from: [
            Piece(text: "one", start: -0.2, end: 2.0, wordTimes: []),
            Piece(text: "two", start: 1.5, end: 3.4, wordTimes: []),
        ], clipSeconds: 3)
        XCTAssertEqual(segments, [Transcript.Segment(text: " one", start: 0, end: 2.0),
                                  Transcript.Segment(text: " two", start: 2.0, end: 3)])
    }

    func testBlankResultsAreDropped() {
        XCTAssertEqual(AppleSpeechSegments.segments(from: [], clipSeconds: 3), [])
        XCTAssertEqual(AppleSpeechSegments.segments(from: [Piece(text: "  ", start: 0, end: 3, wordTimes: [])],
                                                    clipSeconds: 3), [])
    }

    // MARK: - Engine descriptor

    func testRegisteredButOfferedOnlyOnMacOS26WithTheHardware() {
        XCTAssertNotNil(EngineRegistry.shared.descriptor(for: .appleSpeech))
        let engine = AppleSpeechEngine(transcriberAvailable: { true })
        XCTAssertEqual(engine.availability(in: .mac(15)), .unavailable(reason: "Apple Speech needs macOS 26"))
        XCTAssertEqual(engine.availability(in: .mac(26)), .available)
        XCTAssertEqual(AppleSpeechEngine(transcriberAvailable: { false }).availability(in: .mac(26)),
                       .unavailable(reason: "this Mac doesn't support Apple Speech"))
    }

    /// A model that isn't downloaded (or still downloading) reports
    /// `.missing` with a Settings hint; an unsupported language loads, to fail
    /// with its reason.
    func testPresenceIsTheAssetState() {
        let spec = ModelSpec.appleSpeech(language: "en")
        for (state, present) in [(AppleSpeechAssetState.installed, true), (.unsupported, true),
                                 (.notInstalled, false), (.downloading(progress: 0.3), false)] {
            XCTAssertEqual(AppleSpeechEngine(assetState: { _ in state }).isPresent(spec), present, "\(state)")
        }
        guard case .instructions(let text)? = AppleSpeechEngine().downloadHint(for: spec) else {
            return XCTFail("expected Settings instructions")
        }
        XCTAssertTrue(text.contains("Settings"))
    }

    /// An OS query that doesn't answer in time leaves the state unknown,
    /// which must read as missing (download hint, re-checked later), never
    /// as installed (a load that then fails as `.failed`).
    func testAnUnansweredAssetQueryIsNotInstalled() {
        let start = Date()
        let state = AppleSpeechEngine.assetState(within: 0.05) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .installed
        }
        XCTAssertEqual(state, .notInstalled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(AppleSpeechEngine.assetState(within: 5) { .installed }, .installed)
    }

    func testTheModelIsTheLanguageWhateverTheModelArgument() {
        let engine = AppleSpeechEngine()
        XCTAssertEqual(engine.spec(forModelArgument: "anything", language: "de"),
                       ModelSpec(path: ModelSpec.appleSpeechModelPath, sha256: nil, language: "de", engine: .appleSpeech))
        XCTAssertEqual(engine.spec(forModelArgument: "x", language: "").language, ModelSpec.autoDetect)
        XCTAssertEqual(engine.spec(forModelArgument: "x", language: "de").displayName, "Apple Speech on-device model")
    }
}
