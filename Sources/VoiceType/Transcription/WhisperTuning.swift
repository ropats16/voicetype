import Foundation

/// The whisper.cpp decoding knobs #7 benchmarks. `default` is what the app
/// ships: today's decoding, plus non-speech tokens suppressed. Thread count is
/// a separate setting (`Config.threads`), passed alongside.
///
/// Encodes flat, as the bench report records it:
/// `{"suppressNonSpeech": true, "audioContext": "off"|"clip",
///   "temperatureFallback": true, "vad": null|"<silero model path>"}`.
struct WhisperTuning: Codable, Equatable {
    /// How much of the encoder's 30 s window to run.
    enum AudioContext: String, Codable, CaseIterable {
        /// The model's full 1500 frames (whisper.cpp `audio_ctx = 0`).
        case full = "off"
        /// Just enough frames for the clip (`audioContext(forSampleCount:)`):
        /// faster on short clips, at some accuracy risk.
        case sizedToClip = "clip"
    }

    /// Voice-activity detection before decoding: whisper.cpp's built-in
    /// Silero VAD drops silence, and only speech is transcribed.
    enum VAD: Equatable {
        case off
        /// A ggml Silero model, e.g. `ggml-silero-v6.2.0.bin`
        /// (`scripts/download_vad_model.sh`).
        case silero(modelPath: String)

        var modelPath: String? {
            if case .silero(let path) = self { return path }
            return nil
        }
    }

    /// whisper.cpp `suppress_nst`: never decode non-speech tokens (♪, brackets,
    /// "(music)"-style tags).
    var suppressNonSpeech = true
    var audioContext: AudioContext = .full
    /// Re-decode at rising temperatures (whisper.cpp `temperature_inc` 0.2,
    /// its default) when a greedy decode looks bad; off = one decode at 0.
    var temperatureFallback = true
    var vad: VAD = .off

    static let `default` = WhisperTuning()

    /// One line in the bench's flag vocabulary, e.g.
    /// `suppress-nst on · audio-ctx off · temp-fallback on · vad off`.
    var summary: String {
        let onOff = { (b: Bool) in b ? "on" : "off" }
        let vadName = vad.modelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "off"
        return "suppress-nst \(onOff(suppressNonSpeech)) · audio-ctx \(audioContext.rawValue) · "
            + "temp-fallback \(onOff(temperatureFallback)) · vad \(vadName)"
    }

    // MARK: - Encoder context sizing

    /// The encoder runs 1500 frames per 30 s window: one per 320 samples at 16 kHz.
    static let samplesPerFrame = 320
    static let fullAudioContext = 1500
    /// Frames added past the clip's end, so speech at the very end isn't cut.
    static let audioContextPadding = 64
    /// Sizes are rounded up to a multiple of this (fewer distinct GPU shapes).
    static let audioContextBlock = 64
    /// Never fewer frames than this (~5 s): very small contexts make whisper
    /// hallucinate.
    static let minAudioContext = 256

    /// whisper.cpp `audio_ctx` for a clip of `sampleCount` 16 kHz samples:
    /// the clip's frames + padding, rounded up to a block, at least
    /// `minAudioContext`; 0 (the model's full window) once that reaches 1500,
    /// i.e. for clips of about 28.5 s or more.
    static func audioContext(forSampleCount sampleCount: Int) -> Int32 {
        let frames = (max(0, sampleCount) + samplesPerFrame - 1) / samplesPerFrame + audioContextPadding
        let blocks = (frames + audioContextBlock - 1) / audioContextBlock
        let sized = max(minAudioContext, blocks * audioContextBlock)
        return sized >= fullAudioContext ? 0 : Int32(sized)
    }

    /// `audio_ctx` for this tuning: 0 (full) unless sized to the clip.
    func audioContext(forSampleCount sampleCount: Int) -> Int32 {
        audioContext == .sizedToClip ? Self.audioContext(forSampleCount: sampleCount) : 0
    }

    /// whisper.cpp `temperature_inc`: 0 disables the fallback.
    var temperatureIncrement: Float { temperatureFallback ? 0.2 : 0 }
}

extension WhisperTuning.VAD: Codable {
    /// `null` for off, else the model path.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .off : .silero(modelPath: try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let modelPath { try c.encode(modelPath) } else { try c.encodeNil() }
    }
}
