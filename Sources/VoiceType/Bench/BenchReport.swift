import Foundation

/// One bench run, as written to JSON: what ran, where, and what it measured.
/// The schema is versioned; bump `schemaVersion` on any breaking change so
/// runs from different Macs and commits stay comparable.
struct BenchReport: Codable, Equatable {
    struct Machine: Codable, Equatable {
        /// CPU brand, e.g. "Apple M2 Pro".
        let chip: String
        /// Hardware model identifier, e.g. "Mac14,10".
        let model: String
        let memoryBytes: UInt64
        let performanceCores: Int?
        let efficiencyCores: Int?
        let osVersion: String
        /// `ProcessInfo.thermalState` at the start; a hot Mac benches slow.
        let thermalState: String
    }

    struct Engine: Codable, Equatable {
        let id: String
        let modelFile: String
        let modelBytes: UInt64
    }

    struct Build: Codable, Equatable {
        /// "debug" or "release"; only release numbers are comparable.
        let configuration: String
        /// The source commit, "-dirty" if uncommitted changes; nil if unknown.
        let gitSHA: String?
    }

    struct Settings: Codable, Equatable {
        let shortRuns: Int
    }

    var schemaVersion = 1
    /// ISO 8601, UTC.
    let createdAt: String
    let machine: Machine
    let engine: Engine
    let build: Build
    let settings: Settings
    let results: BenchResults

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The human-readable summary printed after a run.
    func table() -> String {
        var out: [String] = []
        let r = results
        out.append("VoiceType bench · \(engine.id) · \(engine.modelFile) (\(mib(engine.modelBytes))) · "
                   + "\(build.configuration) · \(build.gitSHA ?? "unknown commit")")
        let cores = [performanceCoresLabel, efficiencyCoresLabel].compactMap { $0 }.joined(separator: " + ")
        out.append("\(machine.chip) (\(machine.model)\(cores.isEmpty ? "" : ", \(cores)")) · "
                   + "\(mib(machine.memoryBytes, gib: true)) · macOS \(machine.osVersion) · thermal \(machine.thermalState)")
        out.append("")
        out.append("Load      adapter \(secs(r.load.adapterSeconds))  warm-up \(secs(r.load.warmUpSeconds))  "
                   + "total \(secs(r.load.totalSeconds))")
        if let m = r.memory {
            out.append("Memory    baseline \(mib(m.baselineBytes))  loaded \(mib(m.loadedBytes))  "
                       + "peak \(mib(m.peakBytes))  lifetime peak \(mib(m.lifetimePeakBytes))  (phys_footprint)")
        } else {
            out.append("Memory    unavailable")
        }

        if !r.short.clips.isEmpty {
            out.append("")
            out.append("Short dictation (\(settings.shortRuns) run\(settings.shortRuns == 1 ? "" : "s") each)")
            out.append(row(["clip", "audio", "median", "min", "max", "WER"], widths: [24, 8, 8, 8, 8, 7]))
            for c in r.short.clips {
                out.append(row([c.id, secs(c.audioSeconds, 1), ms(c.medianLatencySeconds),
                                ms(c.latenciesSeconds.min() ?? 0), ms(c.latenciesSeconds.max() ?? 0),
                                pct(c.wer.rate)], widths: [24, 8, 8, 8, 8, 7]))
            }
            if let l = r.short.latency {
                out.append("latency p50 \(ms(l.p50Seconds))  p90 \(ms(l.p90Seconds))  mean \(ms(l.meanSeconds))  "
                           + "max \(ms(l.maxSeconds))  (n=\(l.count))  ·  WER \(pct(r.short.wer.rate)) "
                           + "(\(r.short.wer.errors)/\(r.short.wer.referenceWords) words)")
            }
        }

        if !r.long.clips.isEmpty {
            out.append("")
            out.append("Long audio")
            out.append(row(["clip", "audio", "time", "RTF", "speed", "WER"], widths: [24, 8, 8, 8, 8, 7]))
            for c in r.long.clips {
                out.append(row([c.id, secs(c.audioSeconds, 0), secs(c.processingSeconds, 1),
                                String(format: "%.3f", c.realTimeFactor), speed(c.realTimeFactor), pct(c.wer.rate)],
                               widths: [24, 8, 8, 8, 8, 7]))
            }
            if let rtf = r.long.realTimeFactor {
                out.append("RTF \(String(format: "%.3f", rtf)) (\(speed(rtf)) real time)  ·  WER \(pct(r.long.wer.rate)) "
                           + "(\(r.long.wer.errors)/\(r.long.wer.referenceWords) words)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private var performanceCoresLabel: String? { machine.performanceCores.map { "\($0)P" } }
    private var efficiencyCoresLabel: String? { machine.efficiencyCores.map { "\($0)E" } }

    private func row(_ cells: [String], widths: [Int]) -> String {
        zip(cells, widths).enumerated().map { i, pair in
            let (cell, width) = pair
            let pad = String(repeating: " ", count: max(0, width - cell.count))
            return i == 0 ? cell + pad : pad + cell     // first column left-aligned, numbers right
        }.joined(separator: " ")
    }

    private func secs(_ s: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)fs", s) }
    private func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }
    private func pct(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }
    private func speed(_ rtf: Double) -> String { rtf > 0 ? String(format: "%.1fx", 1 / rtf) : "-" }
    private func mib(_ bytes: UInt64, gib: Bool = false) -> String {
        gib ? String(format: "%.0f GiB", Double(bytes) / 1_073_741_824)
            : String(format: "%.0f MiB", Double(bytes) / 1_048_576)
    }
}
