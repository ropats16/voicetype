import Foundation

/// A global key binding. Three forms:
/// - **Modifier combo** (default hold = fn+Shift): `keyCode < 0`, `modifiers`
///   lists the pure modifiers that must be held together. Types nothing.
/// - **Single modifier** (e.g. Right Option): `modifiers` empty, `keyCode` is the
///   modifier's key code; left/right is distinguished via the device bit.
/// - **Regular key + modifiers** (e.g. ⌃⌥Space): `keyCode` is the key, with
///   `modifiers`.
struct KeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: [String]   // any of: "command", "option", "control", "shift", "function"

    /// fn + Shift — default hold-to-talk. A pure-modifier combo, so it never
    /// inserts a character into the focused field (unlike a Space-based combo).
    static let fnShift = KeyBinding(keyCode: -1, modifiers: ["function", "shift"])
    /// Right Option (⌥) — alternative single-modifier hold.
    static let rightOption = KeyBinding(keyCode: 61, modifiers: [])
    /// ⌃⌥Space — default toggle key (wired in Phase 2).
    static let controlOptionSpace = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
}

/// User-editable configuration, persisted as JSON at `Paths.configFile`.
///
/// Decoding is tolerant: any missing key falls back to its default, so a
/// hand-edited or older config keeps working and new fields are forward-safe.
struct Config: Codable {
    var modelPath: String
    var hold: KeyBinding
    var toggle: KeyBinding
    var cancelKeyCode: Int          // Esc = 53
    var maxRecordingSeconds: Double
    var trailingSpace: Bool
    var microphoneUID: String?      // nil = system default input
    var soundCues: Bool
    var language: String
    var threads: Int                // 0 = auto

    static var defaults: Config {
        Config(
            modelPath: Paths.defaultModelFile.path,
            hold: .fnShift,
            toggle: .controlOptionSpace,
            cancelKeyCode: 53,
            maxRecordingSeconds: 120,
            trailingSpace: false,
            microphoneUID: nil,
            soundCues: false,
            language: "en",
            threads: 0
        )
    }

    init(modelPath: String, hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int,
         maxRecordingSeconds: Double, trailingSpace: Bool, microphoneUID: String?,
         soundCues: Bool, language: String, threads: Int) {
        self.modelPath = modelPath
        self.hold = hold
        self.toggle = toggle
        self.cancelKeyCode = cancelKeyCode
        self.maxRecordingSeconds = maxRecordingSeconds
        self.trailingSpace = trailingSpace
        self.microphoneUID = microphoneUID
        self.soundCues = soundCues
        self.language = language
        self.threads = threads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? d.modelPath
        hold = try c.decodeIfPresent(KeyBinding.self, forKey: .hold) ?? d.hold
        toggle = try c.decodeIfPresent(KeyBinding.self, forKey: .toggle) ?? d.toggle
        cancelKeyCode = try c.decodeIfPresent(Int.self, forKey: .cancelKeyCode) ?? d.cancelKeyCode
        maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        soundCues = try c.decodeIfPresent(Bool.self, forKey: .soundCues) ?? d.soundCues
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
    }
}
