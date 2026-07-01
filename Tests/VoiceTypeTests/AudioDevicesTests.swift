import XCTest
@testable import VoiceType

/// Tests for AudioDevices.resolveSelection — the pure decision that maps
/// a configured UID + currently available devices to the UID to actually use.
/// Hardware-touching helpers (inputDevices, deviceID(forUID:)) are not tested
/// because headless test hosts may have no audio hardware.
final class AudioDevicesTests: XCTestCase {

    // MARK: - Fixtures

    private let mic1 = AudioInputDevice(uid: "uid-builtin", name: "Built-in Microphone")
    private let mic2 = AudioInputDevice(uid: "uid-usb", name: "USB Headset")

    // MARK: - nil configuredUID → always nil (use system default)

    func testNilConfiguredUID_returnsNil() {
        XCTAssertNil(
            AudioDevices.resolveSelection(configuredUID: nil, available: [mic1, mic2]),
            "nil UID must always resolve to nil (system default)"
        )
    }

    // MARK: - configuredUID present in available → return that UID

    func testKnownUID_presentInAvailable_returnsThatUID() {
        XCTAssertEqual(
            AudioDevices.resolveSelection(configuredUID: "uid-usb", available: [mic1, mic2]),
            "uid-usb",
            "A UID found in available must be returned as-is"
        )
    }

    // MARK: - configuredUID NOT in available → nil (device unplugged → graceful default)

    func testKnownUID_notInAvailable_returnsNil() {
        XCTAssertNil(
            AudioDevices.resolveSelection(configuredUID: "uid-gone", available: [mic1, mic2]),
            "An unplugged device UID must fall back to nil (system default)"
        )
    }

    // MARK: - empty available list → nil regardless of configured UID

    func testNonNilUID_emptyAvailable_returnsNil() {
        XCTAssertNil(
            AudioDevices.resolveSelection(configuredUID: "uid-builtin", available: []),
            "No available devices must fall back to nil (system default)"
        )
    }
}
