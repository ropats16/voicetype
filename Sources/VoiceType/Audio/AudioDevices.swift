import AVFoundation
import CoreAudio

/// A single audio input device visible to the system.
struct AudioInputDevice: Equatable {
    let uid: String
    let name: String
}

/// Helpers for enumerating and selecting audio input devices.
enum AudioDevices {

    /// All currently available audio input devices.
    ///
    /// Uses `AVCaptureDevice.DiscoverySession` with the input device types
    /// available on macOS 14 (`.microphone` for built-in, `.external` for
    /// USB / Bluetooth / aggregate devices). The `uniqueID` of each
    /// `AVCaptureDevice` equals the Core Audio device UID consumed by
    /// `deviceID(forUID:)`.
    static func inputDevices() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Resolves a Core Audio device UID string to an `AudioDeviceID` via
    /// `kAudioHardwarePropertyTranslateUIDToDevice`. Returns `nil` if no
    /// device with that UID is currently attached.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let cfUID = uid as CFString
        let status: OSStatus = withUnsafePointer(to: cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Pure decision: given the configured UID and the currently available
    /// devices, return the UID to actually use, or `nil` for system default.
    ///
    /// - `nil` configuredUID                    → `nil` (system default)
    /// - configuredUID present in `available`   → configuredUID
    /// - configuredUID NOT in `available`       → `nil` (unplugged → graceful default)
    static func resolveSelection(configuredUID: String?, available: [AudioInputDevice]) -> String? {
        guard let uid = configuredUID else { return nil }
        return available.contains(where: { $0.uid == uid }) ? uid : nil
    }
}
