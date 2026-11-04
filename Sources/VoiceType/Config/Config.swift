import Foundation

/// User-editable configuration, persisted as JSON at `Paths.configFile`.
///
/// Decoding is tolerant: any missing key falls back to its default, so a
/// hand-edited or older config keeps working and new fields are forward-safe.
struct Config: Codable {
    /// A catalog model id (e.g. "small.en-q5_1") or "auto" = pick by chip + RAM.
    var model: String
    /// A specific model file; overrides `model` when non-empty. Older configs
    /// carry one, so an existing choice keeps working.
    var modelPath: String
    var hold: KeyBinding
    var toggle: KeyBinding
    var cancelKeyCode: Int          // Esc = 53
    var maxRecordingSeconds: Double // <= 0 = no limit (a 30-min ceiling still applies)
    var trailingSpace: Bool
    var microphoneUID: String?      // nil = system default input
    var soundCues: Bool
    var language: String
    var threads: Int                // 0 = auto
    var keepMicWarm: Bool           // no Settings UI: mic stays on from launch (pre-roll on every dictation)
    var keepModelWarm: Bool?        // nil = auto: unload when idle only on Macs with <= 8 GB
    var modelIdleMinutes: Double    // idle time before unloading, when not kept warm

    static var defaults: Config {
        Config(
            model: ModelSelection.automatic,
            modelPath: "",
            hold: .controlShift,
            toggle: .controlOptionSpace,
            cancelKeyCode: KeyBinding.escapeKeyCode,
            maxRecordingSeconds: 600,
            trailingSpace: false,
            microphoneUID: nil,
            soundCues: false,
            language: "en",
            threads: 0,
            keepMicWarm: false,
            keepModelWarm: nil,
            modelIdleMinutes: 5
        )
    }

    init(model: String = ModelSelection.automatic, modelPath: String, hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int,
         maxRecordingSeconds: Double, trailingSpace: Bool, microphoneUID: String?,
         soundCues: Bool, language: String, threads: Int, keepMicWarm: Bool,
         keepModelWarm: Bool? = nil, modelIdleMinutes: Double = 5) {
        self.model = model
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
        self.keepMicWarm = keepMicWarm
        self.keepModelWarm = keepModelWarm
        self.modelIdleMinutes = modelIdleMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
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
        keepMicWarm = try c.decodeIfPresent(Bool.self, forKey: .keepMicWarm) ?? d.keepMicWarm
        keepModelWarm = try c.decodeIfPresent(Bool.self, forKey: .keepModelWarm)
        modelIdleMinutes = try c.decodeIfPresent(Double.self, forKey: .modelIdleMinutes) ?? d.modelIdleMinutes
    }
}

/// The max dictation lengths offered in Settings, in seconds (0 = no limit).
enum DictationLimit {
    static let choices: [Double] = [120, 300, 600, 1800, 0]

    /// "10 min", "90 s", or "No limit" for `<= 0`.
    static func label(_ seconds: Double) -> String {
        guard seconds > 0 else { return "No limit" }
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole) s"
    }
}
