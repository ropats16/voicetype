import Foundation

/// The seam between `TranscriptionEngine` and a concrete speech engine. Only
/// the engine calls it: it guarantees calls are serialized and off the main
/// thread, so adapters need no locking of their own.
protocol TranscriptionAdapter: AnyObject {
    /// Transcribe 16 kHz mono Float32 PCM into timestamped segments. Blocks
    /// until done.
    func transcribe(samples: [Float]) throws -> [Transcript.Segment]
}
