import XCTest
import AVFoundation
import CAudioRing
@testable import VoiceType

/// Tests for `AudioCapture` through its interface, driven by the WAV-file
/// adapter in place of the mic: synthetic WAVs are pushed a few seconds at a
/// time, so pre-roll, post-roll and idle timing are all virtual — no mic, no
/// sleeps.
@MainActor
final class AudioCaptureTests: XCTestCase {

    // MARK: - Fixtures

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Writes a 16-bit PCM WAV of `seconds` at `rate`, each channel's sample at
    /// time `t` given by `signal(t, channel)`.
    private func makeWav(rate: Double, channels: AVAudioChannelCount = 1, seconds: Double,
                         _ signal: (Double, Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let total = Int((seconds * rate).rounded())
        let chunk = 65_536
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            for ch in 0..<Int(channels) {
                let out = buffer.floatChannelData![ch]
                for i in 0..<n { out[i] = signal(Double(written + i) / rate, ch) }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            written += n
        }
        return url
    }

    private func sine(_ hz: Double, amplitude: Float = 0.5) -> (Double, Int) -> Float {
        { t, _ in amplitude * Float(sin(2 * .pi * hz * t)) }
    }

    /// Begins a recording and waits until the source is running, so audio
    /// pushed next is captured.
    private func begin(_ capture: AudioCapture) async {
        let started = expectation(description: "source started")
        capture.begin { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
    }

    /// Ends the recording, then pushes `postRoll` seconds of source audio (the
    /// audio that arrives after the key is released), and waits for the result.
    private func end(_ capture: AudioCapture, _ source: WavFileSource? = nil, thenPush postRoll: Double = 0) async -> [Float] {
        var result: [Float] = []
        let ended = expectation(description: "recording ended")
        capture.end { result = $0; ended.fulfill() }
        _ = capture.retainedSampleCount   // the end is registered: what follows is post-roll
        if postRoll > 0 { source?.push(seconds: postRoll) }
        await fulfillment(of: [ended], timeout: 5)
        return result
    }

    /// Records the whole file from a cold start.
    private func recordWholeFile(_ url: URL) async throws -> [Float] {
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source)
        await begin(capture)
        source.push()
        return await end(capture, source)
    }

    /// Frequency from positive-going zero crossings, ignoring the edges.
    private func frequency(_ samples: [Float], rate: Double = 16_000) -> Double {
        let body = samples.dropFirst(samples.count / 10).dropLast(samples.count / 10)
        var crossings = 0
        var previous = body.first ?? 0
        for s in body.dropFirst() {
            if previous < 0 && s >= 0 { crossings += 1 }
            previous = s
        }
        return Double(crossings) / (Double(body.count) / rate)
    }

    private func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // MARK: - Resampling

    func testResamplesCommonRatesTo16kWithLengthAndFrequencyPreserved() async throws {
        for rate in [48_000.0, 44_100.0, 16_000.0] {
            let samples = try await recordWholeFile(try makeWav(rate: rate, seconds: 1, sine(440)))

            XCTAssertEqual(samples.count, 16_000, accuracy: 1, "\(rate) Hz: 1 s must become 16 000 samples, tail drained")
            XCTAssertEqual(frequency(samples), 440, accuracy: 2, "\(rate) Hz: pitch must survive resampling")
        }
    }

    func testStereoIsDownmixedByAveragingChannels() async throws {
        // Left carries a 0.5-amplitude tone, right is silent: an average gives a
        // 0.25 tone; taking either channel alone would give 0.5 or silence.
        let url = try makeWav(rate: 48_000, channels: 2, seconds: 1) { t, ch in
            ch == 0 ? 0.5 * Float(sin(2 * .pi * 440 * t)) : 0
        }

        let samples = try await recordWholeFile(url)

        XCTAssertEqual(samples.count, 16_000, accuracy: 1)
        XCTAssertEqual(rms(samples), 0.25 / Float(2).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(frequency(samples), 440, accuracy: 2)
    }

    // MARK: - Post-roll

    func testEndKeepsTheNext200msSoTheLastWordIsntClipped() async throws {
        // 0.5 s of silence while the key is held, then a tone that starts at
        // the instant of release.
        let url = try makeWav(rate: 48_000, seconds: 1.5) { t, _ in
            t < 0.5 ? 0 : 0.5 * Float(sin(2 * .pi * 440 * t))
        }
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source)

        await begin(capture)
        source.push(seconds: 0.5)
        let samples = await end(capture, source, thenPush: 0.5)

        XCTAssertEqual(samples.count, 11_200, accuracy: 8, "0.5 s held + 0.2 s post-roll (± resampler latency), and no more")
        XCTAssertLessThan(rms(samples[1_000..<7_000]), 0.01, "Held audio comes first")
        XCTAssertGreaterThan(rms(samples[8_500..<11_000]), 0.3, "The tail after release is kept")
    }

    // MARK: - Pre-roll

    /// Silence, then a tone from 2.0 s on.
    private func toneFromTwoSeconds() throws -> URL {
        try makeWav(rate: 48_000, seconds: 3.5) { t, _ in
            t < 2 ? 0 : 0.5 * Float(sin(2 * .pi * 440 * t))
        }
    }

    func testWarmBeginIncludesSpeechThatStartedJustBefore() async throws {
        let source = try WavFileSource(url: try toneFromTwoSeconds())
        let capture = AudioCapture(source: source)
        // A first recording leaves the source warm.
        await begin(capture)
        source.push(seconds: 0.5)
        _ = await end(capture, source, thenPush: 0.2)
        // The tone starts at 2.0 s; the key goes down at 2.2 s.
        source.push(seconds: 1.5)

        await begin(capture)
        source.push(seconds: 0.5)
        let samples = await end(capture, source, thenPush: 0.2)

        XCTAssertEqual(samples.count, 16_000, accuracy: 8, "0.3 s pre-roll + 0.5 s held + 0.2 s post-roll")
        XCTAssertLessThan(rms(samples[0..<1_400]), 0.01, "Pre-roll reaches 0.3 s back, into the silence")
        XCTAssertGreaterThan(rms(samples[1_800..<4_800]), 0.3, "The tone's first 0.2 s, before the press, is kept")
    }

    func testColdBeginStartsAtTheFirstSourceSample() async throws {
        let source = try WavFileSource(url: try toneFromTwoSeconds())
        let capture = AudioCapture(source: source)
        source.push(seconds: 2.2)   // nothing is listening yet

        await begin(capture)
        source.push(seconds: 0.5)
        let samples = await end(capture, source, thenPush: 0.2)

        XCTAssertEqual(samples.count, 11_200, accuracy: 8, "No pre-roll: 0.5 s held + 0.2 s post-roll")
        XCTAssertGreaterThan(rms(samples[0..<3_000]), 0.3)
    }

    // MARK: - Warm policy

    func testSourceStaysWarmFor30sAfterARecordingThenStops() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 16_000, seconds: 40) { _, _ in 0 })
        let capture = AudioCapture(source: source)
        await begin(capture)
        source.push(seconds: 0.5)
        _ = await end(capture, source, thenPush: 0.2)

        source.push(seconds: 29)
        XCTAssertTrue(source.isRunning, "Still warm inside the 30 s window")
        source.push(seconds: 2)
        XCTAssertFalse(source.isRunning, "Stopped once idle for 30 s")
    }

    func testKeepWarmRunsFromWarmUpAndIdleMemoryStaysFixedForTenMinutes() throws {
        let source = try WavFileSource(url: try makeWav(rate: 16_000, seconds: 600) { _, _ in 0 })
        let capture = AudioCapture(source: source, keepWarm: true)
        try capture.warmUp()

        source.push(seconds: 60)
        let afterOneMinute = capture.retainedSampleCount
        source.push(seconds: 539)

        XCTAssertTrue(source.isRunning, "keepWarm never idles out")
        XCTAssertEqual(afterOneMinute, 4_800, "Idle audio is only the 0.3 s pre-roll")
        XCTAssertEqual(capture.retainedSampleCount, afterOneMinute, "…however long the source idles")
    }

    func testWarmMaxDurationRecordingKeepsItsPreRollAndPostRoll() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 48_000, seconds: 4, sine(440)))
        let capture = AudioCapture(source: source, maxSeconds: { 1 })
        try capture.warmUp()
        source.push(seconds: 1)

        await begin(capture)
        source.push(seconds: 1)   // held for the full max duration
        let samples = await end(capture, source, thenPush: 0.2)

        XCTAssertEqual(samples.count, 24_000, accuracy: 8,
                       "0.3 s pre-roll + 1 s max + 0.2 s post-roll: the cap mustn't eat speech")
    }

    func testRecordingStopsGrowingAtTheCap() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 48_000, seconds: 4, sine(440)))
        let capture = AudioCapture(source: source, maxSeconds: { 1 })

        await begin(capture)
        source.push(seconds: 2)
        let atTwoSeconds = capture.retainedSampleCount
        source.push(seconds: 1)

        XCTAssertEqual(atTwoSeconds, 24_000, "Cap = pre-roll + max + post-roll")
        XCTAssertEqual(capture.retainedSampleCount, 24_000)
        let samples = await end(capture, source, thenPush: 0.5)
        XCTAssertEqual(samples.count, 24_000)
    }

    func testNoConfiguredCapStillStopsAtThirtyMinutes() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 8_000, seconds: 32 * 60) { _, _ in 0 })
        let capture = AudioCapture(source: source, maxSeconds: { 0 })

        await begin(capture)
        source.push(seconds: 31 * 60)

        let ceiling = 30 * 60 * 16_000 + 8_000   // + 0.5 s of pre- and post-roll
        XCTAssertEqual(capture.retainedSampleCount, ceiling, "Memory stays bounded with no limit set")
        let samples = await end(capture, source, thenPush: 0.5)
        XCTAssertEqual(samples.count, ceiling)
    }

    // MARK: - Route changes

    func testRecordingAfterAFormatChangeIsStillCorrect() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 48_000, seconds: 2, sine(440)))
        let capture = AudioCapture(source: source)
        await begin(capture)
        source.push(seconds: 1)
        _ = await end(capture, source, thenPush: 0.2)

        // E.g. a headset is plugged in: the source now runs at 44.1 kHz.
        try source.open(try makeWav(rate: 44_100, seconds: 2, sine(880)))
        await begin(capture)
        source.push(seconds: 1)
        let samples = await end(capture, source, thenPush: 0.2)

        XCTAssertEqual(samples.count, 19_200, accuracy: 8, "1 s held + 0.2 s post-roll, resampled at the new rate")
        XCTAssertEqual(frequency(samples), 880, accuracy: 2)
    }

    func testRouteChangeNoticeWithNothingChangedKeepsTheSourceRunning() async throws {
        let source = try WavFileSource(url: try makeWav(rate: 48_000, seconds: 3, sine(440)))
        let capture = AudioCapture(source: source)
        await begin(capture)
        source.push(seconds: 1)
        _ = await end(capture, source, thenPush: 0.5)
        let warm = capture.retainedSampleCount

        // Core Audio reports property changes that change nothing too, e.g.
        // as a device is selected; restarting on each one loops forever.
        source.onEvent?(.routeChanged)

        XCTAssertEqual(capture.retainedSampleCount, warm, "Pre-roll survives: no restart happened")
        XCTAssertTrue(source.isRunning)
    }

    func testARouteThatKeepsChangingStopsTheSourceUntilTheNextRecording() async throws {
        let url = try makeWav(rate: 48_000, seconds: 3, sine(440))
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source)
        await begin(capture)
        source.push(seconds: 0.5)
        _ = await end(capture, source, thenPush: 0.2)

        for _ in 0..<4 {
            try source.open(url)
            _ = capture.retainedSampleCount   // wait for the capture to handle it
        }
        XCTAssertFalse(source.isRunning, "The fourth restart within the window is refused")

        await begin(capture)
        source.push(seconds: 1)
        let samples = await end(capture, source, thenPush: 0.2)
        XCTAssertEqual(samples.count, 19_200, accuracy: 8, "The next recording starts the source fresh")
    }

    // MARK: - Silent sources

    /// A running source that never writes: a mic gone quiet under a format
    /// change.
    private final class SilentSource: AudioSource {
        var onEvent: ((AudioSourceEvent) -> Void)?
        let needsRestart = false
        let stallTimeout: TimeInterval?
        private(set) var starts = 0
        init(stallTimeout: TimeInterval?) { self.stallTimeout = stallTimeout }
        func start(_ input: CaptureInput) throws -> Double { starts += 1; return 48_000 }
        func stop() {}
    }

    func testEndFinishesEvenWhenThePostRollNeverArrives() async throws {
        let capture = AudioCapture(source: SilentSource(stallTimeout: nil))
        await begin(capture)

        let finished = expectation(description: "end completes")
        capture.end { _ in finished.fulfill() }

        await fulfillment(of: [finished], timeout: AudioCapture.postRollSeconds + AudioCapture.endGraceSeconds + 1)
    }

    func testASourceThatStopsDeliveringIsRestarted() async throws {
        let source = SilentSource(stallTimeout: 0.05)
        let capture = AudioCapture(source: source)
        await begin(capture)

        try await Task.sleep(nanoseconds: 300_000_000)
        _ = capture.retainedSampleCount   // wait for the capture's queue

        XCTAssertGreaterThan(source.starts, 1, "A stalled source is restarted")
        XCTAssertLessThanOrEqual(source.starts, 4, "…but never in a loop: at most 3 restarts in the window")
    }

    // MARK: - Cold start

    /// A mic that takes `delay` to come up, then delivers 0.1 s of a 48 kHz
    /// tone: its first audio.
    private final class SlowSource: AudioSource {
        var onEvent: ((AudioSourceEvent) -> Void)?
        let needsRestart = false
        let stallTimeout: TimeInterval? = nil
        private let delay: TimeInterval
        private let error: Error?
        init(delay: TimeInterval, failingWith error: Error? = nil) {
            self.delay = delay
            self.error = error
        }
        func start(_ input: CaptureInput) throws -> Double {
            Thread.sleep(forTimeInterval: delay)
            if let error { throw error }
            var tone = (0..<4_800).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
            tone.withUnsafeMutableBufferPointer { samples in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: samples.baseAddress))
                _ = vt_ring_write_downmix(input.ring, &buffers, UInt32(samples.count))
            }
            return 48_000
        }
        func stop() {}
    }

    func testColdBeginReturnsAtOnceAndStillRecordsTheFirstAudio() async throws {
        let capture = AudioCapture(source: SlowSource(delay: 0.5))
        let started = expectation(description: "source started")

        let elapsed = ContinuousClock().measure {
            capture.begin { error in
                XCTAssertNil(error)
                started.fulfill()
            }
        }

        XCTAssertLessThan(elapsed, .milliseconds(100), "Main isn't held up by the mic starting")
        XCTAssertTrue(capture.isRecording)
        await fulfillment(of: [started], timeout: 5)
        let samples = await end(capture)
        XCTAssertEqual(samples.count, 1_600, accuracy: 8, "The recording begins at the first sample")
        XCTAssertGreaterThan(rms(samples[100..<1_500]), 0.3)
    }

    func testAColdStartThatFailsEndsTheRecordingAndReportsIt() async throws {
        let capture = AudioCapture(source: SlowSource(delay: 0.1, failingWith: MicSourceError.noInputAvailable))
        let started = expectation(description: "start reported")
        var reported: Error?

        capture.begin { reported = $0; started.fulfill() }
        XCTAssertTrue(capture.isRecording, "Recording until the failure is known")
        await fulfillment(of: [started], timeout: 5)

        XCTAssertNotNil(reported)
        XCTAssertFalse(capture.isRecording)
    }
}
