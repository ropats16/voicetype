import AppKit

/// Which moment in the dictation lifecycle a cue marks.
enum SoundCue { case start, stop }

/// The side-effecting sink that actually plays audio.
/// Production code uses `SystemSoundCueOutput`; tests inject a spy.
protocol SoundCueOutput {
    func emit(_ cue: SoundCue)
}

/// Plays subtle built-in macOS system sounds from /System/Library/Sounds by name,
/// so no audio assets are bundled with the app. "Tink" marks start (short, bright)
/// and "Pop" marks stop (short, muted). NSSound instances are cached at init time.
/// If a sound name can't be loaded (e.g. on an unusual OS image) the failure is
/// silently swallowed — no crash, no log spam.
final class SystemSoundCueOutput: SoundCueOutput {
    private let startSound: NSSound?
    private let stopSound: NSSound?

    init() {
        startSound = NSSound(named: "Tink")
        stopSound  = NSSound(named: "Pop")
    }

    func emit(_ cue: SoundCue) {
        switch cue {
        case .start: startSound?.play()
        case .stop:  stopSound?.play()
        }
    }
}

/// Gates sound-cue playback on a live-read enabled flag.
///
/// `isEnabled` is called on every `play(_:)` invocation so toggling
/// `config.soundCues` at runtime is honoured immediately without
/// recreating the `SoundCues` instance.
final class SoundCues {
    private let isEnabled: () -> Bool
    private let output: SoundCueOutput

    init(isEnabled: @escaping () -> Bool,
         output: SoundCueOutput = SystemSoundCueOutput()) {
        self.isEnabled = isEnabled
        self.output    = output
    }

    /// Plays `cue` through the configured output, but only when enabled.
    func play(_ cue: SoundCue) {
        guard isEnabled() else { return }
        output.emit(cue)
    }
}
