import Foundation

/// `VoiceType --selftest --model <ggml.bin> --wav <file.wav>`
///
/// Loads the model and transcribes a WAV file (any sample rate or channel
/// count), printing the result. The file is played through the audio capture's
/// WAV adapter, so it's resampled exactly like the mic. A quick way to confirm
/// the capture + Whisper/Metal path works without granting permissions or
/// speaking into a mic.
enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let model = value("--model"), let wav = value("--wav") else {
            FileHandle.standardError.write(Data("usage: VoiceType --selftest --model <ggml.bin> --wav <file.wav>\n".utf8))
            return 2
        }

        do {
            let samples = try capture(wav: URL(fileURLWithPath: wav))
            let seconds = Double(samples.count) / AudioCapture.sampleRate
            err("Loaded \(samples.count) samples (\(String(format: "%.1f", seconds))s @ 16 kHz)")

            err("Loading model: \(model)")
            let engine = TranscriptionEngine.whisper(modelPath: model, language: "en", threads: 0)
            let loadStart = Date()
            engine.load()
            while engine.status == .loading { Thread.sleep(forTimeInterval: 0.01) }
            switch engine.status {
            case .ready:
                err("Model loaded and warmed up in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")
            case .missing:
                err("selftest failed: model file not found at \(model)")
                return 1
            case .failed(let reason):
                err("selftest failed: \(reason)")
                return 1
            case .notLoaded, .loading:
                break   // unreachable: load() was called and the loop above waits it out
            }

            let start = Date()
            let text = try blocking { try await engine.transcribe(samples).text }
            let elapsed = Date().timeIntervalSince(start)

            err("Transcribed in \(String(format: "%.2f", elapsed))s")
            print(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return 0
        } catch {
            err("selftest failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Records the whole file through the capture. Its result arrives on main,
    /// so spin the main run loop until it does.
    private static func capture(wav url: URL) throws -> [Float] {
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source)
        try capture.begin()
        source.push()
        var samples: [Float]?
        capture.end { samples = $0 }
        while samples == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return samples!
    }

    /// Runs async work to completion from this synchronous CLI path. The
    /// engine never needs the main thread, so blocking it here is safe.
    private static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8))
    }
}
