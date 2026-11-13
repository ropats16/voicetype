import Foundation

/// `VoiceType --selftest --wav <file.wav> [--model <ggml.bin>] [--engine <id>]`
///
/// Loads the model (with no `--model`, the engine's Automatic pick for this
/// Mac and English, which must be installed; apple-speech has no model files)
/// and transcribes a WAV file (any sample rate or channel count), printing
/// the result. The file is played through the audio capture's
/// WAV adapter, so it's resampled exactly like the mic. A quick way to confirm
/// the capture + engine (whisper/Metal by default) path works without granting
/// permissions or speaking into a mic. For timings and accuracy, use `--bench`
/// (`Bench/`).
enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        guard let wav = CommandLineSupport.value("--wav", in: arguments) else {
            FileHandle.standardError.write(Data(
                "usage: VoiceType --selftest --wav <file.wav> [--model <ggml.bin>] [--engine <id>]\n".utf8))
            return 2
        }
        let modelArgument = CommandLineSupport.value("--model", in: arguments)
        let engineID = CommandLineSupport.value("--engine", in: arguments) ?? EngineKind.whisper.rawValue
        let engines = EngineRegistry.shared
        if case .unavailable(let reason) = engines.availability(ofID: engineID, in: .current) {
            err("selftest failed: \(reason)")
            return 2
        }
        let descriptor = engines.descriptor(for: EngineKind(rawValue: engineID)!)!
        // whisper: verified against its pinned checksum if the catalog knows the file.
        let spec: ModelSpec
        do {
            spec = try descriptor.commandLineSpec(modelArgument: modelArgument,
                                                  in: CommandLineSupport.modelContext(language: "en"))
        } catch {
            err("selftest failed: \(error.localizedDescription)")
            return 1
        }
        let model = spec.path

        do {
            let samples = try CommandLineSupport.samples(fromAudioFile: URL(fileURLWithPath: wav))
            let seconds = Double(samples.count) / AudioCapture.sampleRate
            err("Loaded \(samples.count) samples (\(String(format: "%.1f", seconds))s @ 16 kHz)")

            err("Loading model: \(model)\(modelArgument == nil ? " (Automatic)" : "")")
            let engine = TranscriptionEngine.registered(model: spec, options: EngineOptions())
            let loadStart = Date()
            engine.load()
            while [.notLoaded, .loading, .verifying].contains(engine.status) { Thread.sleep(forTimeInterval: 0.01) }
            switch engine.status {
            case .ready:
                err("Model loaded and warmed up in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")
            case .missing:
                err("selftest failed: model not found at \(model)")
                return 1
            case .failed(let reason):
                err("selftest failed: \(reason)")
                return 1
            case .notLoaded, .loading, .verifying:
                break   // unreachable: load() was called and the loop above waits it out
            }

            let start = Date()
            let text = try CommandLineSupport.blocking { try await engine.transcribe(samples).text }
            let elapsed = Date().timeIntervalSince(start)

            err("Transcribed in \(String(format: "%.2f", elapsed))s")
            print(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return 0
        } catch {
            err("selftest failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8))
    }
}
