import Foundation

/// `VoiceType --selftest --model <ggml.bin> --wav <16kHz.wav>`
///
/// Loads the model and transcribes a WAV file, printing the result. A quick way
/// to confirm the Whisper/Metal engine works without granting permissions or
/// speaking into a mic.
enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let model = value("--model"), let wav = value("--wav") else {
            FileHandle.standardError.write(Data("usage: VoiceType --selftest --model <ggml.bin> --wav <16kHz.wav>\n".utf8))
            return 2
        }

        do {
            let audio = try WavReader.load(path: wav)
            let seconds = Double(audio.samples.count) / Double(audio.sampleRate)
            err("Loaded \(audio.samples.count) samples (\(String(format: "%.1f", seconds))s @ \(audio.sampleRate) Hz)")
            if audio.sampleRate != 16000 {
                err("warning: expected 16 kHz audio; got \(audio.sampleRate) Hz — transcription may be off")
            }

            err("Loading model: \(model)")
            let transcriber = try WhisperTranscriber(modelPath: model, language: "en", threads: 0)

            let start = Date()
            let text = try transcriber.transcribe(samples: audio.samples)
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
