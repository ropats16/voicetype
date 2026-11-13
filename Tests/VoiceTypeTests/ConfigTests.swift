import XCTest
@testable import VoiceType

/// Tolerant decoding of `Config`: missing keys fall back to defaults.
final class ConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testKeepMicWarmDefaultsToOffWhenMissing() throws {
        XCTAssertFalse(try decode("{}").keepMicWarm)
        XCTAssertFalse(Config.defaults.keepMicWarm)
    }

    func testKeepMicWarmIsReadWhenPresent() throws {
        XCTAssertTrue(try decode(#"{"keepMicWarm": true}"#).keepMicWarm)
    }

    // MARK: - Model keys

    func testAFreshConfigAutoPicksTheModel() throws {
        let c = try decode("{}")
        XCTAssertEqual(c.model, .automatic)
        XCTAssertEqual(c.modelPath, "", "No hard-coded medium.en default any more")
        XCTAssertNil(c.keepModelWarm, "Keep-warm defaults to automatic (by RAM)")
        XCTAssertEqual(c.modelIdleMinutes, 5)
        XCTAssertEqual(c.language, "en")
    }

    /// #15: a config without an `engine` key goes Automatic, unless it
    /// hand-picked a whisper model — then it stays on whisper.
    func testEngineKeyDefaultsRespectAnOlderWhisperPick() throws {
        XCTAssertEqual(try decode("{}").engine, EngineChoice.automaticID)
        XCTAssertEqual(try decode(#"{"modelPath": "/m/ggml-medium.en.bin"}"#).engine, "whisper")
        XCTAssertEqual(try decode(#"{"model": "small.en-q5_1"}"#).engine, "whisper")
        XCTAssertEqual(try decode(#"{"model": "auto"}"#).engine, EngineChoice.automaticID)
        XCTAssertEqual(try decode(#"{"engine": "parakeet", "modelPath": "/m/x.bin"}"#).engine, "parakeet")
    }

    func testAnOlderConfigKeepsItsModelPath() throws {
        // What earlier versions (and setup.sh) wrote: modelPath, no model key.
        let old = "/Users/me/Library/Application Support/VoiceType/models/ggml-medium.en.bin"
        let c = try decode(#"{"modelPath": "\#(old)", "language": "en", "threads": 0}"#)
        XCTAssertEqual(c.modelPath, old)
        XCTAssertEqual(c.engineChoice, .engine(.whisper), "No engine key + a hand-set file: stays on whisper")
        // Whenever whisper runs (always on Intel), the file beats its auto-pick.
        let spec = ModelSelection.resolve(c, hardware: HardwareProfile(isAppleSilicon: false, memoryBytes: 8 << 30),
                                          presentFilenames: [])
        XCTAssertEqual(spec.path, old, "An explicit file beats the auto-pick")
    }

    func testNewModelKeysAreRead() throws {
        let c = try decode(#"{"model": "small-q5_1", "language": "de", "keepModelWarm": false, "modelIdleMinutes": 2}"#)
        XCTAssertEqual(c.model, .named("small-q5_1"))
        XCTAssertEqual(c.language, "de")
        XCTAssertEqual(c.keepModelWarm, false)
        XCTAssertEqual(c.modelIdleMinutes, 2)
    }

    func testModelKeysRoundTrip() throws {
        var c = Config.defaults
        c.model = .named("base.en-q8_0")
        c.keepModelWarm = true
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.model, .named("base.en-q8_0"))
        XCTAssertEqual(back.keepModelWarm, true)
    }

    // MARK: - Support folder override

    func testSupportFolderOverrideIsSharedWithTheScripts() {
        let standard = "Library/Application Support/VoiceType"
        XCTAssertEqual(Paths.appSupportDir(environment: ["VOICETYPE_APP_SUPPORT": "/srv/vt"]).path, "/srv/vt")
        XCTAssertTrue(Paths.appSupportDir(environment: ["VOICETYPE_APP_SUPPORT": ""]).path.hasSuffix(standard),
                      "Empty means unset, as in the scripts")
        XCTAssertTrue(Paths.appSupportDir(environment: [:]).path.hasSuffix(standard))
    }
}
