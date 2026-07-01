import Foundation
import AVFoundation

/// Captures microphone audio and produces a 16 kHz mono Float32 PCM buffer —
/// the format Whisper expects. Resampling from the hardware format is done on
/// the fly with `AVAudioConverter`.
final class AudioRecorder {
    /// Whisper's required sample rate.
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Called on the audio thread with a 0...1 RMS level for the waveform UI.
    var onLevel: ((Float) -> Void)?

    /// Core Audio UID of the preferred input device. `nil` means use whatever
    /// the system selects as the default input. Set this before calling `start()`.
    var preferredDeviceUID: String? = nil

    enum AudioError: LocalizedError {
        case noInputAvailable
        case converterInitFailed
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputAvailable: return "No microphone input is available."
            case .converterInitFailed: return "Could not initialize the audio converter."
            case .engineStartFailed(let msg): return "Could not start the audio engine: \(msg)"
            }
        }
    }

    func start() throws {
        guard !isRecording else { return }

        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode

        // Select the preferred device BEFORE reading the hardware format so
        // that the converter is built against the chosen device's sample rate
        // and channel layout. If the UID can't be resolved (e.g. device
        // unplugged since the user picked it), we log and fall back to the
        // system default — recording must never fail due to a bad UID.
        if let uid = preferredDeviceUID {
            if let deviceID = AudioDevices.deviceID(forUID: uid) {
                do {
                    try input.auAudioUnit.setDeviceID(deviceID)
                } catch {
                    Log.info("Could not select device '\(uid)': \(error.localizedDescription). Using default.")
                }
            } else {
                Log.info("Preferred mic UID '\(uid)' not found; using system default.")
            }
        }

        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioError.noInputAvailable
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioError.converterInitFailed
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error.localizedDescription)
        }
        isRecording = true
    }

    /// Stops capture and returns the full 16 kHz mono Float32 buffer.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return currentSamples() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        return currentSamples()
    }

    /// Stops capture and discards the audio (cancel path).
    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        lock.lock(); samples.removeAll(keepingCapacity: false); lock.unlock()
    }

    /// Seconds of audio captured so far.
    var duration: Double {
        Double(currentSamples().count) / AudioRecorder.targetSampleRate
    }

    private func currentSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = AudioRecorder.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channel = out.floatChannelData else { return }

        let frames = Int(out.frameLength)
        guard frames > 0 else { return }
        let ptr = channel[0]

        // RMS level for the waveform indicator.
        var sumSq: Float = 0
        for i in 0..<frames { let s = ptr[i]; sumSq += s * s }
        let rms = (frames > 0) ? (sumSq / Float(frames)).squareRoot() : 0
        onLevel?(min(1, rms * 4))

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
        lock.unlock()
    }
}
