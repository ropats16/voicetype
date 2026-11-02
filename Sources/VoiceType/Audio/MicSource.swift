import AudioToolbox
import CAudioRing
import CoreAudio
import Foundation

enum MicSourceError: LocalizedError {
    case noInputAvailable
    case startFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No microphone input is available."
        case .startFailed(let step, let status): return "Could not start the microphone: \(step) failed (\(status))."
        }
    }
}

/// Mic adapter: captures the selected input device with an input-only AUHAL.
///
/// Not `AVAudioEngine`: its input node builds an aggregate of the default
/// input and output devices before any device is selected, so every cold
/// start opened the default input and touched the output — on AirPods, a
/// switch to call quality and back, heard as a pop, even with another mic
/// selected — and took ~0.4 s. This unit opens only the chosen input.
///
/// The real-time callback is C (`vt_input_install`): it renders into buffers
/// allocated at start and downmixes them into the ring — no allocation, locks,
/// Swift or ObjC on the audio thread.
final class MicSource: AudioSource {
    var onEvent: ((AudioSourceEvent) -> Void)?

    /// Slice length the render buffers hold at least; device IO buffers are
    /// rarely longer.
    private static let minFramesPerSlice: UInt32 = 4096
    private static let listenerQueue = DispatchQueue(label: "com.local.VoiceType.mic-listeners")

    private let configuredUID: () -> String?
    private let devices: () -> [AudioInputDevice]
    private let deviceIDForUID: (String) -> AudioDeviceID?
    private let defaultDeviceID: () -> AudioDeviceID?

    // Touched only on the capture's queue.
    private var unit: AudioUnit?
    private var render: OpaquePointer?
    private var activeDeviceID: AudioDeviceID?
    private var openedFormat: AudioStreamBasicDescription?
    private var listeners: [Listener] = []

    /// `configuredUID` is read live at each start, so a mic change in Settings
    /// takes effect on the next recording. The device lookups default to Core
    /// Audio; tests inject them.
    init(configuredUID: @escaping () -> String?,
         devices: @escaping () -> [AudioInputDevice] = AudioDevices.inputDevices,
         deviceIDForUID: @escaping (String) -> AudioDeviceID? = AudioDevices.deviceID(forUID:),
         defaultDeviceID: @escaping () -> AudioDeviceID? = AudioDevices.defaultInputDeviceID) {
        self.configuredUID = configuredUID
        self.devices = devices
        self.deviceIDForUID = deviceIDForUID
        self.defaultDeviceID = defaultDeviceID
    }

    /// True when the unit stopped, its input format changed, or a different
    /// mic should be open (including a new system default). Property
    /// notifications also arrive for no-op changes, so the capture asks this
    /// before restarting rather than restarting on every one.
    var needsRestart: Bool {
        guard let unit else { return false }
        let current = Self.hardwareFormat(of: unit)
        return !Self.isRunning(unit)
            || current?.mSampleRate != openedFormat?.mSampleRate
            || current?.mChannelsPerFrame != openedFormat?.mChannelsPerFrame
            || deviceToOpen() != activeDeviceID
    }

    /// A live mic delivers every few milliseconds; a second of nothing means
    /// the unit went quiet under a format change.
    let stallTimeout: TimeInterval? = 1.0

    /// The input to open: the configured mic when it's available, else the
    /// system default (e.g. the configured mic was unplugged).
    func deviceToOpen() -> AudioDeviceID? {
        resolveDevice().device
    }

    /// `isDefault` means no configured mic is available, so the system
    /// default input is used. `missingUID` is the configured mic when it
    /// wasn't available.
    private func resolveDevice() -> (device: AudioDeviceID?, isDefault: Bool, missingUID: String?) {
        let configured = configuredUID()
        if let uid = AudioDevices.resolveSelection(configuredUID: configured, available: devices()),
           let id = deviceIDForUID(uid) {
            return (id, false, nil)
        }
        return (defaultDeviceID(), true, configured)
    }

    func start(_ input: CaptureInput) throws -> Double {
        do { return try open(input) } catch {
            stop()
            throw error
        }
    }

    /// Builds and starts the unit, leaving whatever it got to for `stop`.
    private func open(_ input: CaptureInput) throws -> Double {
        let (resolved, isDefault, missingUID) = resolveDevice()
        if let missingUID { Log.info("Preferred mic UID '\(missingUID)' not found; using system default.") }
        guard var device = resolved else { throw MicSourceError.noInputAvailable }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicSourceError.noInputAvailable }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "creating the input unit")
        guard let unit = created else { throw MicSourceError.noInputAvailable }
        self.unit = unit

        // Input on, output off: the output device is never opened.
        try check(Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)), "enabling input")
        try check(Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)), "disabling output")

        // The unit always needs a device; with no configured mic it's the
        // current default, and the default-input listener plus `needsRestart`
        // follow the default when it changes. A configured mic that can't be
        // selected falls back to the default — recording must never fail over
        // a bad UID.
        var status = Self.set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
        if status != noErr, !isDefault, let fallback = defaultDeviceID() {
            Log.info("Could not select input device \(device) (\(status)). Using default.")
            device = fallback
            status = Self.set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
        }
        try check(status, "selecting the input device")
        activeDeviceID = device

        // Listen before reading the format, so a change during start is caught.
        listen(to: device, kAudioDevicePropertyDeviceIsAlive)
        listen(to: device, kAudioDevicePropertyNominalSampleRate)
        listen(to: device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        listen(to: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)

        guard let hardware = Self.hardwareFormat(of: unit), hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0
        else { throw MicSourceError.noInputAvailable }
        openedFormat = hardware

        // Deinterleaved Float32 at the device's rate and channel count; the
        // capture downmixes and resamples.
        let bytes = UInt32(MemoryLayout<Float>.size)
        let client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: hardware.mChannelsPerFrame, mBitsPerChannel: 8 * bytes, mReserved: 0)
        try check(Self.set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, client), "setting the format")

        // A device whose IO buffer outgrows this later drops slices until the
        // stall watchdog restarts it with the new size.
        let maxFrames = max(Self.minFramesPerSlice, Self.bufferFrameSize(of: device))
        try check(Self.set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maxFrames),
                  "sizing the buffers")
        guard let render = vt_input_create(input.ring, unit, hardware.mChannelsPerFrame, maxFrames)
        else { throw MicSourceError.noInputAvailable }
        self.render = render
        try check(vt_input_install(render), "installing the callback")

        try check(AudioUnitInitialize(unit), "initializing the input unit")
        try check(AudioOutputUnitStart(unit), "starting the input unit")
        return hardware.mSampleRate
    }

    func stop() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, Self.listenerQueue, listener.block)
        }
        listeners = []
        if let unit {
            // Once disposed the unit calls back no more, so `render` can go.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        vt_input_destroy(render)
        render = nil
        activeDeviceID = nil
        openedFormat = nil
    }

    // MARK: - Core Audio helpers

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Reports any change to the property as a possible route change; the
    /// capture checks `needsRestart`.
    private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onEvent?(.routeChanged) }
        guard AudioObjectAddPropertyListenerBlock(object, &address, Self.listenerQueue, block) == noErr else { return }
        listeners.append(Listener(object: object, address: address, block: block))
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw MicSourceError.startFailed(step, status) }
    }

    private static func set<T: BitwiseCopyable>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                               _ element: AudioUnitElement, _ value: T) -> OSStatus {
        var value = value
        return AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size))
    }

    /// The input device's side of the unit (input scope of the input element).
    private static func hardwareFormat(of unit: AudioUnit) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size)
        return status == noErr ? format : nil
    }

    private static func isRunning(_ unit: AudioUnit) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return status == noErr && running != 0
    }

    private static func bufferFrameSize(of device: AudioDeviceID) -> UInt32 {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        return frames
    }
}
