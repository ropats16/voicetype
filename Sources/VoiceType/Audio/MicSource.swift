import AVFoundation
import CAudioRing
import CoreAudio

enum MicSourceError: LocalizedError {
    case noInputAvailable
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No microphone input is available."
        case .engineStartFailed(let msg): return "Could not start the audio engine: \(msg)"
        }
    }
}

/// Mic adapter: captures the selected input device with `AVAudioEngine`.
///
/// The real-time callback is an `AVAudioSinkNode` whose block only calls the C
/// ring's downmix-and-write — no allocation, locks, Swift arrays, ObjC messages
/// or logging on the audio thread. It captures nothing but the ring pointer.
final class MicSource: AudioSource {
    var onEvent: ((AudioSourceEvent) -> Void)?

    private let configuredUID: () -> String?
    private let devices: () -> [AudioInputDevice]
    private let deviceIDForUID: (String) -> AudioDeviceID?
    private let defaultDeviceID: () -> AudioDeviceID?

    // Touched only on the capture's queue.
    private var engine: AVAudioEngine?
    private var activeDeviceID: AudioDeviceID?
    private var openedFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

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

    /// True when the engine stopped itself, its input format changed, or a
    /// different mic should be open. Configuration-change notifications also
    /// arrive for no-op changes (e.g. right after selecting a device), so the
    /// capture asks this before restarting rather than restarting on every one.
    var needsRestart: Bool {
        guard let engine else { return false }
        let current = engine.inputNode.inputFormat(forBus: 0)
        return !engine.isRunning
            || current.sampleRate != openedFormat?.sampleRate
            || current.channelCount != openedFormat?.channelCount
            || deviceToOpen() != activeDeviceID
    }

    /// The input to open: the configured mic when it's available, else the
    /// system default (e.g. the configured mic was unplugged).
    func deviceToOpen() -> AudioDeviceID? {
        resolveDevice().device
    }

    /// `isDefault` means no configured mic is available, so the engine's own
    /// default input is used. `missingUID` is the configured mic when it wasn't
    /// available.
    private func resolveDevice() -> (device: AudioDeviceID?, isDefault: Bool, missingUID: String?) {
        let configured = configuredUID()
        if let uid = AudioDevices.resolveSelection(configuredUID: configured, available: devices()),
           let id = deviceIDForUID(uid) {
            return (id, false, nil)
        }
        return (defaultDeviceID(), true, configured)
    }

    func start(_ input: CaptureInput) throws -> Double {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Select the device BEFORE reading the hardware format, so the format
        // is the chosen device's. A device that can't be selected falls back to
        // the default — recording must never fail over a bad UID. The default
        // is never selected explicitly: the input node already follows it, and
        // selecting it anyway posts a configuration change on every start.
        let (device, isDefault, missingUID) = resolveDevice()
        if let missingUID { Log.info("Preferred mic UID '\(missingUID)' not found; using system default.") }
        if let device, !isDefault {
            do { try inputNode.auAudioUnit.setDeviceID(device) } catch {
                Log.info("Could not select input device \(device): \(error.localizedDescription). Using default.")
            }
        }

        let hardware = inputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount)
        else { throw MicSourceError.noInputAvailable }

        let ring = input.ring
        let sink = AVAudioSinkNode { _, frameCount, buffers in
            vt_ring_write_downmix(ring, buffers, frameCount)
            return noErr
        }
        engine.attach(sink)
        engine.connect(inputNode, to: sink, format: format)

        // Posted when the device's format changes or it goes away, and
        // sometimes for no-op changes; the capture checks `needsRestart`.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onEvent?(.routeChanged) }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeObserver()
            throw MicSourceError.engineStartFailed(error.localizedDescription)
        }
        self.engine = engine
        activeDeviceID = device
        openedFormat = hardware
        return format.sampleRate
    }

    func stop() {
        removeObserver()
        engine?.stop()
        engine = nil
        activeDeviceID = nil
        openedFormat = nil
    }

    private func removeObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }
}
