import Foundation

/// Where a source writes its audio while running.
struct CaptureInput {
    /// The capture's SPSC ring. Write with `vt_ring_write_downmix`, which is
    /// real-time safe and downmixes any channel layout to mono.
    let ring: OpaquePointer
    /// Processes everything written so far before returning. For sources that
    /// aren't real-time (the WAV adapter); never call it from an audio thread.
    let flush: () -> Void
}

/// Something a source tells the capture, from any thread.
enum AudioSourceEvent {
    /// The input's route or format may have changed; the capture restarts
    /// the source if `needsRestart` says so.
    case routeChanged
    /// The source has no more audio (a WAV file hit its end).
    case ended
}

/// The seam between `AudioCapture` and a concrete input (the mic, or a WAV file
/// in tests and `--selftest`). Only the capture calls it, always on its own
/// serial queue, so adapters need no locking for these calls.
protocol AudioSource: AnyObject {
    /// Set once by the capture before the first `start`.
    var onEvent: ((AudioSourceEvent) -> Void)? { get set }

    /// Whether the running source must be restarted: it stopped itself, its
    /// format changed, or a different input should be open (e.g. after the
    /// mic was changed in Settings).
    var needsRestart: Bool { get }

    /// How long the running source may write nothing before the capture treats
    /// it as stalled and restarts it; `nil` = never (sources fed by hand).
    var stallTimeout: TimeInterval? { get }

    /// Starts writing audio into `input.ring` and returns its sample rate.
    func start(_ input: CaptureInput) throws -> Double

    /// Stops writing. Once this returns, nothing more is written to the ring.
    func stop()
}
