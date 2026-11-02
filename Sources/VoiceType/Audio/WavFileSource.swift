import AVFoundation
import CAudioRing

/// WAV-file adapter: plays a file of any sample rate and channel count into
/// the capture, for tests and `--selftest`. Time is virtual — it advances only
/// when `push` is called — so a test can place audio exactly before, during
/// and after a recording.
final class WavFileSource: AudioSource {
    var onEvent: ((AudioSourceEvent) -> Void)?

    private static let chunkFrames: AVAudioFrameCount = 4096

    // `push` runs on the caller's thread; `start`/`stop` on the capture's queue.
    private let lock = NSLock()
    private var file: AVAudioFile
    private var input: CaptureInput?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    /// Whether the capture has the source running.
    var isRunning: Bool { lock.withLock { input != nil } }

    /// After `open` the source has stopped itself; otherwise nothing changes.
    var needsRestart: Bool { !isRunning }

    /// Switches to another file, as if the input device changed: a running
    /// source stops and reports a route change, so the capture restarts it.
    func open(_ url: URL) throws {
        let next = try AVAudioFile(forReading: url)
        let wasRunning = lock.withLock {
            file = next
            let wasRunning = input != nil
            input = nil
            return wasRunning
        }
        if wasRunning { onEvent?(.routeChanged) }
    }

    /// Plays the next `seconds` of the file (by default, the rest of it) as if
    /// captured live: processed by the capture before this returns while the
    /// source runs, lost while it doesn't. Reaching the end reports `.ended`.
    func push(seconds: Double = .infinity) {
        let format = lock.withLock { file.processingFormat }
        var remaining = seconds.isFinite ? Int((seconds * format.sampleRate).rounded()) : Int.max
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else { return }
        var atEnd = false
        while remaining > 0 && !atEnd {
            let sink: CaptureInput? = lock.withLock {
                let frames = AVAudioFrameCount(min(remaining, Int(Self.chunkFrames)))
                do { try file.read(into: buffer, frameCount: frames) } catch { buffer.frameLength = 0 }
                atEnd = buffer.frameLength == 0 || file.framePosition >= file.length
                guard let input else { return nil }
                vt_ring_write_downmix(input.ring, buffer.audioBufferList, buffer.frameLength)
                return input
            }
            remaining -= Int(buffer.frameLength)
            sink?.flush()
        }
        if atEnd { onEvent?(.ended) }
    }

    // MARK: - AudioSource

    func start(_ input: CaptureInput) throws -> Double {
        lock.withLock {
            self.input = input
            return file.processingFormat.sampleRate
        }
    }

    func stop() {
        lock.withLock { input = nil }
    }
}
