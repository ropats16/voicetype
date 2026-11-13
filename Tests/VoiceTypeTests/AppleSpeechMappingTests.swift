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
}
