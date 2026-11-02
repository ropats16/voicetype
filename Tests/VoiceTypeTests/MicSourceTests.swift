import XCTest
import CoreAudio
@testable import VoiceType

/// Which input the mic adapter opens, against injected device lists and
/// Core Audio lookups — the same decision `start()` and `needsRestart` use.
/// Starting the engine itself needs real hardware and mic permission, so it's
/// not exercised here.
final class MicSourceTests: XCTestCase {

    private let builtIn = AudioInputDevice(uid: "uid-builtin", name: "Built-in Microphone")
    private let headset = AudioInputDevice(uid: "uid-usb", name: "USB Headset")
    private let deviceIDs: [String: AudioDeviceID] = ["uid-builtin": 10, "uid-usb": 20]
    private let systemDefault: AudioDeviceID = 10

    private func mic(configured: String?) -> MicSource {
        MicSource(
            configuredUID: { configured },
            devices: { [builtIn, headset] in [builtIn, headset] },
            deviceIDForUID: { [deviceIDs] in deviceIDs[$0] },
            defaultDeviceID: { [systemDefault] in systemDefault }
        )
    }

    func testConfiguredMicThatIsPluggedInIsOpened() {
        XCTAssertEqual(mic(configured: "uid-usb").deviceToOpen(), 20)
    }

    func testConfiguredMicThatIsMissingFallsBackToSystemDefault() {
        XCTAssertEqual(mic(configured: "uid-unplugged").deviceToOpen(), systemDefault)
    }

    func testNoConfiguredMicOpensSystemDefault() {
        XCTAssertEqual(mic(configured: nil).deviceToOpen(), systemDefault)
    }
}
