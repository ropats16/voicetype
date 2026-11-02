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
}
