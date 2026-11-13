import AVFoundation
import Foundation
import Speech

extension TranscriptionEngine {
    /// The adapter factory for Apple's on-device SpeechAnalyzer (macOS 26+),
    /// behind `AppleSpeechEngine`. There's no model file: the
    /// spec's language picks the OS-managed model (`AppleSpeechLocale`) and
    /// `spec.path` is ignored (use `ModelSpec.appleSpeech(language:)`).
    ///
    /// Throws `AppleSpeechError` — `.unavailable` below macOS 26, and
    /// `.modelNotInstalled` if the language's model isn't downloaded: it never
    /// downloads one itself (that's `AppleSpeechAssets.install`).
    static func appleSpeechAdapter() -> (ModelSpec) throws -> TranscriptionAdapter {
        { spec in
            guard #available(macOS 26, *), AppleSpeechAvailability.isAvailable() else {
                throw AppleSpeechError.unavailable
            }
            return try AppleSpeechAdapter(language: spec.language)
        }
    }
}

extension ModelSpec {
    /// Apple's engine has no model file; this stands in for one in `path`
    /// (and reads well in messages: "Apple Speech on-device model").
    /// `AppleSpeechEngine.isPresent` checks the asset state instead.
    static let appleSpeechModelPath = "on-device model"

    static func appleSpeech(language: String) -> ModelSpec {
        ModelSpec(path: appleSpeechModelPath, sha256: nil, language: language, engine: .appleSpeech)
    }
}

/// Errors from the Apple SpeechAnalyzer engine, worded for the user (the
/// engine shows them as its `.failed` reason).
enum AppleSpeechError: LocalizedError, Equatable {
    case unavailable
    /// An ISO code or `ModelSpec.autoDetect`.
    case unsupportedLanguage(String)
    /// The locale's display name, e.g. "English (United States)".
    case modelNotInstalled(String)
    case modelDownloading(String)
    case timedOut
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple speech recognition needs macOS 26 or later on a Mac that supports it."
        case .unsupportedLanguage(let code):
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return "Apple speech recognition doesn't support \(name) on this Mac."
        case .modelNotInstalled(let name):
            return "Apple's \(name) speech model isn't downloaded. Download it in Settings."
        case .modelDownloading(let name):
            return "Apple's \(name) speech model is still downloading."
        case .timedOut:
            return "Apple speech recognition didn't finish in time."
        case .audioConversionFailed:
            return "Couldn't convert the audio for Apple speech recognition."
        }
    }
}

/// Apple's on-device speech-to-text (SpeechAnalyzer + SpeechTranscriber,
/// macOS 26). Inference runs in an OS speech service, not in this process.
///
/// Each job is one finite analysis: the clip is converted to the transcriber's
/// format, streamed in 1 s buffers, and finalized; final results only, with per-word times.
/// The API is async; `transcribe` blocks the engine's queue on it with a
/// deadline (`BlockingAsync.Bridge`). The model is retained for the process's
/// lifetime once used (the engine's warm-up), and released in the background
/// when the adapter goes (unload, or a switch away).
@available(macOS 26, *)
final class AppleSpeechAdapter: TranscriptionAdapter {
    let locale: Locale
    /// The transcriber's preferred audio format (16 kHz mono Int16 in 26.x).
    private let format: AVAudioFormat

    /// Resolves `language` to a locale and checks its model is installed
    /// (reserving the locale for this app), else throws `AppleSpeechError`.
    init(language: String) throws {
        let (locale, format) = try Self.blocking(timeout: Self.setupTimeout) { try await Self.prepare(language) }
        self.locale = locale
        self.format = format
    }

    deinit {
        // In the background: the last reference may drop on main.
        Self.release.start()
    }

    /// Ends the model retention when an adapter goes. The next adapter's
    /// setup waits for it, so a late release can't undo its retention.
    private static let release = PendingRelease { await SpeechModels.endRetention() }

    func transcribe(samples: [Float]) throws -> [Transcript.Segment] {
        guard !samples.isEmpty else { return [] }
        let clipSeconds = Double(samples.count) / AudioCapture.sampleRate
        let buffer = try Self.convert(samples, to: format)
        let pieces = try Self.blocking(timeout: Self.jobTimeout(clipSeconds: clipSeconds)) { [locale] in
            try await Self.analyze(buffer, locale: locale)
        }
        return AppleSpeechSegments.segments(from: pieces, clipSeconds: clipSeconds)
    }

    // MARK: - Setup

    private static let setupTimeout: TimeInterval = 30

    /// Generous: the OS loads the model on a cold first job, and inference
    /// runs far faster than real time.
    static func jobTimeout(clipSeconds: Double) -> TimeInterval { 20 + clipSeconds }

    private static func prepare(_ language: String) async throws -> (Locale, AVAudioFormat) {
        await release.settled()
        guard let locale = await AppleSpeechAssets.locale(for: language) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        switch await AppleSpeechAssets.state(for: locale) {
        case .installed: break
        case .notInstalled: throw AppleSpeechError.modelNotInstalled(name)
        case .downloading: throw AppleSpeechError.modelDownloading(name)
        case .unsupported: throw AppleSpeechError.unsupportedLanguage(language)
        }
        await AppleSpeechAssets.reserve(locale)
        let modules = [AppleSpeechAssets.transcriber(for: locale)]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        return (locale, format)
    }

    // MARK: - Analysis

    /// One whole-clip analysis: feed the buffer, finalize through its end,
    /// collect the final results. Cancelling (the deadline) stops the analyzer.
    private static func analyze(_ buffer: AVAudioPCMBuffer, locale: Locale) async throws -> [AppleSpeechSegments.Piece] {
        let transcriber = AppleSpeechAssets.transcriber(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let collector = Task {
            var pieces: [AppleSpeechSegments.Piece] = []
            for try await result in transcriber.results { pieces.append(.init(result)) }
            return pieces
        }
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        for chunk in try chunks(of: buffer) { feed.yield(AnalyzerInput(buffer: chunk)) }
        feed.finish()

        return try await withTaskCancellationHandler {
            do {
                if let end = try await analyzer.analyzeSequence(input) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await collector.value
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// `buffer` in consecutive pieces of at most `seconds`. Fed one whole long
    /// buffer, the transcriber keeps only its last ~2.5 minutes and drops the
    /// rest without an error; fed as a stream (like a live mic) it hears it all.
    static func chunks(of buffer: AVAudioPCMBuffer, seconds: Double = 1) throws -> [AVAudioPCMBuffer] {
        let format = buffer.format
        let size = max(1, Int(format.sampleRate * seconds))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        return try stride(from: 0, to: Int(buffer.frameLength), by: size).map { offset in
            let frames = min(size, Int(buffer.frameLength) - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw AppleSpeechError.audioConversionFailed
            }
            chunk.frameLength = AVAudioFrameCount(frames)
            for (from, to) in zip(source, UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)) {
                memcpy(to.mData, from.mData! + offset * bytesPerFrame, frames * bytesPerFrame)
            }
            return chunk
        }
    }

    /// 16 kHz mono Float32 → `format` (sample type and, if it differs, rate).
    static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                         channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AppleSpeechError.audioConversionFailed }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        if format == source { return input }

        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / source.sampleRate).rounded(.up)) + 1024
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { throw AppleSpeechError.audioConversionFailed }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .endOfStream; return nil }
            fed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw AppleSpeechError.audioConversionFailed }
        return output
    }

    /// Shared by every adapter: after a deadline, nothing new starts until the
    /// abandoned analysis (or setup) has wound down.
    private static let bridge = BlockingAsync.Bridge(name: "Apple speech recognition")

    /// `bridge.run`, its deadline reported as `AppleSpeechError.timedOut`.
    private static func blocking<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) throws -> T {
        do { return try bridge.run(timeout: timeout, work) } catch is BlockingAsync.TimedOut {
            throw AppleSpeechError.timedOut
        }
    }
}

/// A release that runs in the background, in order, and that whoever must
/// not overlap it can wait for (`settled`).
final class PendingRelease: @unchecked Sendable {
    private let action: @Sendable () async -> Void
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    init(_ action: @escaping @Sendable () async -> Void) { self.action = action }

    /// Starts the release, after any still running; returns at once.
    func start() {
        lock.withLock {
            let previous = last
            last = Task.detached(priority: .userInitiated) { [action] in
                await previous?.value
                await action()
            }
        }
    }

    /// Returns once every release started so far has finished.
    func settled() async {
        await lock.withLock { last }?.value
    }
}

@available(macOS 26, *)
private extension AppleSpeechSegments.Piece {
    init(_ result: SpeechTranscriber.Result) {
        let words = result.text.runs.compactMap(\.audioTimeRange)
            .map { (start: $0.start.seconds, end: $0.end.seconds) }
            .filter { $0.start.isFinite && $0.end.isFinite }
        self.init(text: String(result.text.characters), start: result.range.start.seconds,
                  end: result.range.end.seconds, wordTimes: words)
    }
}

/// Maps the transcriber's final results to the engine's segments.
enum AppleSpeechSegments {
    /// One final result: its text, its audio range, and its words' ranges
    /// (seconds from the clip's start; empty if not reported).
    struct Piece {
        let text: String
        let start: Double
        let end: Double
        let wordTimes: [(start: Double, end: Double)]
    }

    /// One segment per non-blank result, in order. Text gets the single
    /// leading space whisper.cpp segments carry, so `Transcript.text` joins
    /// both engines alike (the transcriber puts one on all but the first).
    /// Times span the words when known (tighter than the result's range),
    /// kept within the clip and never before the previous segment's end.
    static func segments(from pieces: [Piece], clipSeconds: Double) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var previousEnd = 0.0
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = min(max(piece.wordTimes.map(\.start).min() ?? piece.start, previousEnd), clipSeconds)
            let end = min(max(piece.wordTimes.map(\.end).max() ?? piece.end, start), clipSeconds)
            segments.append(Transcript.Segment(text: " " + text, start: start, end: end))
            previousEnd = end
        }
        return NonSpeechFilter.filter(segments)
    }
}
