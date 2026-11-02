import AVFoundation
import CAudioRing

enum AudioCaptureError: LocalizedError {
    case converterInitFailed

    var errorDescription: String? {
        switch self {
        case .converterInitFailed: return "Could not initialize the audio converter."
        }
    }
}

/// Records 16 kHz mono Float32 audio — the format Whisper expects — from an
/// `AudioSource` adapter (the mic, or a WAV file).
///
/// The source writes into a lock-free ring from its real-time thread; a serial
/// queue drains it, resamples, and keeps the pre-roll and recording. All other
/// state, and every call into the source, lives on that queue.
///
/// Main-thread API: call `begin`, `end` and `cancel` on main; callbacks arrive
/// on main.
final class AudioCapture {
    static let sampleRate: Double = 16_000
    /// Audio kept from before `begin` while the source is warm, so speech that
    /// starts at the instant of key press isn't clipped.
    static let preRollSeconds = 0.3
    /// Audio kept after `end`, so the last word isn't clipped by an early release.
    static let postRollSeconds = 0.2
    /// How long the source stays warm after a recording, unless `keepWarm`.
    /// Long enough for back-to-back dictations; short enough that the mic
    /// indicator and Bluetooth call-quality mode don't linger.
    static let idleSeconds = 30.0
    /// Longest press when the config sets no limit, so memory is always
    /// bounded (~115 MB).
    static let ceilingSeconds = 30.0 * 60
    /// Slack past the post-roll before `end` gives up waiting for audio, so a
    /// source that went silent can't leave a recording unfinished.
    static let endGraceSeconds = 0.8

    /// 0...1 RMS level of the recording, for the waveform UI.
    var onLevel: ((Float) -> Void)?

    /// True from `begin()` until `end` or `cancel`.
    private(set) var isRecording = false

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Source frames resampled per converter call.
    private static let chunkFrames: AVAudioFrameCount = 4096

    private let source: AudioSource
    private let keepWarm: Bool
    private let maxSeconds: () -> Double
    private let queue = DispatchQueue(label: "com.local.VoiceType.capture", qos: .userInitiated)

    // Everything below is touched only on `queue` (the ring's write side
    // belongs to the source).
    private let ring: OpaquePointer
    private var isRunning = false
    private var converter: AVAudioConverter?
    private var sourceBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var timer: DispatchSourceTimer?
    private var preRoll = PreRoll(capacity: Int(preRollSeconds * sampleRate))
    private var recording: [Float]?
    private var recordingCap = Int.max
    /// Set by `end`: post-roll samples still to record, and who gets the result.
    private var pendingEnd: (remaining: Int, completion: ([Float]) -> Void)?
    /// Counts `end` calls, so a late end timeout can't finish a newer recording.
    private var endCount = 0
    /// When the source last wrote audio, for the stall check.
    private var lastAudioAt: TimeInterval = 0
    /// When route-change restarts happened, to stop a restart loop.
    private var recentRestarts: [TimeInterval] = []
    private static let maxRestartsPerWindow = 3
    private static let restartWindowSeconds = 2.0
    /// Samples since the last recording ended, for the idle stop.
    private var idleSamples = 0

    /// `keepWarm` keeps the source running once started instead of stopping it
    /// after `idleSeconds`. `maxSeconds` is the longest press (read at `begin`;
    /// `<= 0` = `ceilingSeconds`); a recording holds at most that plus pre- and
    /// post-roll.
    init(source: AudioSource, keepWarm: Bool = false, maxSeconds: @escaping () -> Double = { 0 }) {
        self.source = source
        self.keepWarm = keepWarm
        self.maxSeconds = maxSeconds
        // ~1.4 s at 48 kHz: far more than one drain interval.
        ring = vt_ring_create(1 << 16)!
        source.onEvent = { [weak self] event in
            guard let self else { return }
            queue.async { self.handle(event) }
        }
    }

    // Touching queue state here is safe: every queue block holds `self`
    // strongly (the timer's handler for its whole run), so deinit can't overlap
    // queue work. No `queue.sync` — deinit may run on the queue itself.
    deinit {
        timer?.cancel()
        if isRunning { source.stop() }
        vt_ring_destroy(ring)
    }

    // MARK: - Main-thread API

    /// Starts a recording. A warm source contributes its pre-roll; a cold one
    /// is started, and the recording begins at its first sample.
    func begin() throws {
        guard !isRecording else { return }
        let press = maxSeconds() > 0 ? maxSeconds() : Self.ceilingSeconds
        let cap = Int((press + Self.preRollSeconds + Self.postRollSeconds) * Self.sampleRate)
        try queue.sync { try beginRecording(cap: cap) }
        isRecording = true
    }

    /// Ends the recording once the post-roll is in (sooner if the source stops);
    /// `completion` gets its samples on main. Takes a completion rather than
    /// being `async` so the end is registered at the call, i.e. at key release.
    func end(_ completion: @escaping ([Float]) -> Void) {
        guard isRecording else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        isRecording = false
        queue.async { [self] in
            drainRingAndStopIfIdle()
            pendingEnd = (Int(Self.postRollSeconds * Self.sampleRate), completion)
            endCount += 1
            if !isRunning { finishRecording(); return }
            let thisEnd = endCount
            queue.asyncAfter(deadline: .now() + Self.postRollSeconds + Self.endGraceSeconds) { [self] in
                guard endCount == thisEnd, pendingEnd != nil else { return }
                Log.error("Post-roll audio never arrived; finishing the recording without it.")
                finishRecording()
            }
        }
    }

    /// Starts the source without recording, so the next `begin` has pre-roll.
    func warmUp() throws {
        try queue.sync { if !isRunning { try startSource() } }
    }

    /// Samples held in memory (pre-roll plus recording), for tests.
    var retainedSampleCount: Int {
        queue.sync { preRoll.count + (recording?.count ?? 0) }
    }

    /// Discards the recording.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        queue.async { [self] in
            recording = nil
            idleSamples = 0
        }
    }

    // MARK: - Recording (on queue)

    private func beginRecording(cap: Int) throws {
        finishRecording()   // a previous recording still in its post-roll ends here
        if isRunning && source.needsRestart { stopSource() }
        if !isRunning { try startSource() }
        drainRingAndStopIfIdle()
        recording = []
        recordingCap = cap
        preRoll.take().withUnsafeBufferPointer { record($0) }
    }

    private func finishRecording() {
        guard let completion = pendingEnd?.completion else { return }
        let samples = recording ?? []
        recording = nil
        pendingEnd = nil
        idleSamples = 0
        DispatchQueue.main.async { completion(samples) }
    }

    /// Takes 16 kHz samples from the converter.
    private func deliver(_ samples: UnsafeBufferPointer<Float>) {
        var rest = samples[...]
        if recording != nil {
            let take = min(rest.count, pendingEnd?.remaining ?? .max)
            record(UnsafeBufferPointer(rebasing: rest.prefix(take)))
            rest = rest.dropFirst(take)
            if let remaining = pendingEnd?.remaining {
                pendingEnd!.remaining = remaining - take
                if remaining == take { finishRecording() }
            }
        }
        preRoll.append(UnsafeBufferPointer(rebasing: rest))
        if recording == nil { idleSamples += rest.count }
    }

    /// Appends to the recording, up to its cap.
    private func record(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let room = recordingCap - recording!.count
        guard room > 0 else { return }
        let kept = UnsafeBufferPointer(rebasing: samples.prefix(room))
        recording!.append(contentsOf: kept)

        var sumSquares: Float = 0
        for s in kept { sumSquares += s * s }
        let level = min(1, (sumSquares / Float(kept.count)).squareRoot() * 4)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: - Source lifecycle (on queue)

    private func startSource() throws {
        vt_ring_reset(ring)
        let rate = try source.start(CaptureInput(ring: ring, flush: { [weak self] in
            guard let self else { return }
            queue.sync { self.drainRingAndStopIfIdle() }
        }))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: format, to: Self.format),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.format,
                frameCapacity: AVAudioFrameCount((Double(Self.chunkFrames) * Self.sampleRate / rate).rounded(.up)) + 64)
        else {
            source.stop()
            throw AudioCaptureError.converterInitFailed
        }
        self.converter = converter
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
        isRunning = true
        idleSamples = 0
        lastAudioAt = ProcessInfo.processInfo.systemUptime

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drainRingAndStopIfIdle() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the source and drains the converter so the tail isn't lost.
    private func stopSource() {
        guard isRunning else { return }
        source.stop()
        timer?.cancel()
        timer = nil
        drainRing()
        convert(nil)
        converter = nil
        sourceBuffer = nil
        outputBuffer = nil
        isRunning = false
        preRoll.clear()
        finishRecording()
    }

    private func handle(_ event: AudioSourceEvent) {
        switch event {
        case .ended:
            stopSource()
        case .routeChanged:
            guard isRunning, source.needsRestart else { return }
            restartSource(because: "Audio route changed")
        }
    }

    /// Restarts a running source, keeping any recording in progress.
    private func restartSource(because reason: String) {
        stopSource()
        // A route that keeps changing (or a source that keeps reporting it, or
        // keeps stalling) would otherwise restart the mic forever; stop
        // instead, and let the next `begin` start it fresh.
        let now = ProcessInfo.processInfo.systemUptime
        recentRestarts = recentRestarts.filter { now - $0 < Self.restartWindowSeconds } + [now]
        guard recentRestarts.count <= Self.maxRestartsPerWindow else {
            Log.error("\(reason) again; stopping the microphone until the next recording.")
            recentRestarts = []
            return
        }
        Log.info("\(reason); restarting capture.")
        do { try startSource() } catch {
            Log.error("Could not restart audio capture: \(error.localizedDescription)")
        }
    }

    // MARK: - Draining + resampling (on queue)

    /// Resamples everything the source has written, restarts it if it has
    /// stalled, then stops it if it has idled past `idleSeconds`.
    private func drainRingAndStopIfIdle() {
        drainRing()
        // E.g. AirPods switching to call quality as the mic opens: the device
        // changes format under the engine, which can go silent without the
        // change ever looking like one when it's reported.
        if isRunning, let timeout = source.stallTimeout,
           ProcessInfo.processInfo.systemUptime - lastAudioAt > timeout {
            restartSource(because: "Microphone stopped delivering audio")
        }
        if isRunning && !keepWarm && recording == nil && idleSamples >= Int(Self.idleSeconds * Self.sampleRate) {
            Log.info("Microphone idle for \(Int(Self.idleSeconds))s; stopping.")
            stopSource()
        }
    }

    private func drainRing() {
        guard let sourceBuffer else { return }
        while true {
            let n = vt_ring_read(ring, sourceBuffer.floatChannelData![0], sourceBuffer.frameCapacity)
            guard n > 0 else { return }
            lastAudioAt = ProcessInfo.processInfo.systemUptime
            sourceBuffer.frameLength = n
            convert(sourceBuffer)
        }
    }

    /// Resamples `input` into the output buffer and delivers the result; a nil
    /// `input` flushes what the converter still holds (end of stream).
    private func convert(_ input: AVAudioPCMBuffer?) {
        guard let converter, let outputBuffer else { return }
        var supplied = false
        var status: AVAudioConverterOutputStatus
        repeat {
            var error: NSError?
            status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                guard let input else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                Log.error("Audio conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            deliver(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)))
        } while status == .haveData
    }
}

/// Fixed-size ring holding the most recent idle samples.
private struct PreRoll {
    private var storage: [Float]
    private var start = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        let capacity = storage.count
        for s in samples.suffix(capacity) {
            storage[(start + count) % capacity] = s
            if count < capacity { count += 1 } else { start = (start + 1) % capacity }
        }
    }

    /// Empties the ring, returning its samples oldest first.
    mutating func take() -> [Float] {
        let ordered = (0..<count).map { storage[(start + $0) % storage.count] }
        clear()
        return ordered
    }

    mutating func clear() {
        start = 0
        count = 0
    }
}
