import Foundation

/// A global key binding. For modifier-only triggers (e.g. Right Option as
/// hold-to-talk) `modifiers` is empty and `keyCode` is the modifier's key code.
struct KeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: [String]   // any of: "command", "option", "control", "shift"

    /// Right Option (⌥) — default hold-to-talk key. Reported on flagsChanged.
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
            hold: .rightOption,
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
