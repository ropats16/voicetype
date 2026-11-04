import Foundation

/// The bench's arithmetic, kept pure so it's tested directly.
enum BenchStats {
    /// The `p`th percentile (0...100) by linear interpolation between closest
    /// ranks (numpy's default), or nil for no values. Input order doesn't matter.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(max(p, 0), 100) / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }

    /// Processing time over audio duration: < 1 is faster than real time
    /// (0.05 = 20× faster). 0 for empty audio.
    static func realTimeFactor(processingSeconds: Double, audioSeconds: Double) -> Double {
        audioSeconds > 0 ? processingSeconds / audioSeconds : 0
    }

    /// Distribution of a set of latencies, in seconds.
    struct LatencySummary: Codable, Equatable {
        let count: Int
        let p50Seconds: Double
        let p90Seconds: Double
        let meanSeconds: Double
        let minSeconds: Double
        let maxSeconds: Double

        /// nil for no latencies.
        init?(_ latencies: [Double]) {
            guard let p50 = percentile(latencies, 50), let p90 = percentile(latencies, 90),
                  let min = latencies.min(), let max = latencies.max() else { return nil }
            count = latencies.count
            p50Seconds = p50
            p90Seconds = p90
            meanSeconds = latencies.reduce(0, +) / Double(latencies.count)
            minSeconds = min
            maxSeconds = max
        }
    }
}
