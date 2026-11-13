import Foundation

/// Shared plumbing for the diagnostic command-line modes (`--selftest`,
/// `--bench`), which run synchronously on main before the app would start.
enum CommandLineSupport {
    /// The value after `flag` in `arguments`, if any.
    static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// What an engine's Automatic pick looks at when `--model` is omitted:
    /// this Mac and the models folder as they are now. A hand-set
    /// `modelPath` in config.json is ignored: pass it as `--model`.
    static func modelContext(language: String) -> ModelContext {
        ModelContext(language: language.isEmpty ? ModelSpec.autoDetect : language, hardware: .current,
                     modelsDir: Paths.modelsDir, presentFilenames: ModelSelection.presentFilenames())
    }

    /// Decodes an audio file (any sample rate or channel count) to 16 kHz mono
    /// by playing it through the audio capture's WAV adapter — resampled
    /// exactly like the mic. The capture's callbacks arrive on main, so this
    /// spins the main run loop until they do.
    static func samples(fromAudioFile url: URL) throws -> [Float] {
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source)
        var started: Error??
        capture.begin { started = $0 }
        while started == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        if let error = started! { throw error }
        source.push()
        var samples: [Float]?
        capture.end { samples = $0 }
        while samples == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return samples!
    }

    /// Runs async work to completion from a synchronous CLI path. The engine
    /// never needs the main thread, so blocking it here is safe.
    static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
