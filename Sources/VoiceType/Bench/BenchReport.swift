import Foundation

/// One bench run, as written to JSON: what ran, where, and what it measured.
/// The schema is versioned: every key is always present (absent values are
/// `null`), and `schemaVersion` is bumped on any breaking change, so runs from
/// different Macs and commits stay comparable.
struct BenchReport: Codable, Equatable {
    struct Machine: Codable, Equatable {
        /// CPU brand, e.g. "Apple M2 Pro".
        let chip: String
        /// Hardware model identifier, e.g. "Mac14,10".
        let model: String
        let memoryBytes: UInt64
        /// Null on Macs without performance levels (Intel).
        @NullWhenAbsent var performanceCores: Int?
        @NullWhenAbsent var efficiencyCores: Int?
        let osVersion: String
        /// `ProcessInfo.thermalState` before and after the run; a Mac that
        /// heated up mid-run benches slow.
        let thermalStateAtStart: String
        let thermalStateAtEnd: String
    }

    struct Engine: Codable, Equatable {
        let id: String
        let modelFile: String
        /// The model file's size, or the total of a model directory's files
        /// (e.g. `.mlmodelc`); null if the path doesn't exist.
        @NullWhenAbsent var modelBytes: UInt64?
    }

    struct Build: Codable, Equatable {
        /// "debug" or "release"; only release numbers are comparable.
        let configuration: String
        /// From `--git-sha`; null if not given.
        @NullWhenAbsent var gitSHA: String?
    }

    struct Settings: Codable, Equatable {
        let shortRuns: Int
        let language: String
        /// 0 = the engine's own default.
        let threads: Int
        /// The whisper.cpp knobs the run used (other engines ignore them).
        var whisper: WhisperTuning = .default
    }

    var schemaVersion = 2
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
        out.append("VoiceType bench · \(engine.id) · \(engine.modelFile) (\(engine.modelBytes.map { mib($0) } ?? "no file")) · "
                   + "\(build.configuration) · \(build.gitSHA ?? "commit unknown")")
        let cores = [machine.performanceCores.map { "\($0)P" }, machine.efficiencyCores.map { "\($0)E" }]
            .compactMap { $0 }.joined(separator: " + ")
        let thermal = machine.thermalStateAtStart == machine.thermalStateAtEnd
            ? machine.thermalStateAtStart : "\(machine.thermalStateAtStart) → \(machine.thermalStateAtEnd)"
        out.append("\(machine.chip) (\(machine.model)\(cores.isEmpty ? "" : ", \(cores)")) · "
                   + "\(gib(machine.memoryBytes)) · macOS \(machine.osVersion) · thermal \(thermal)")
        out.append("language \(settings.language) · threads \(settings.threads == 0 ? "auto" : String(settings.threads)) · "
                   + settings.whisper.summary)
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
            out.append(row(["clip", "audio", "median", "min", "max", "WER"]))
            for c in r.short.clips {
                out.append(row([c.id, secs(c.audioSeconds, 1), ms(c.medianLatencySeconds),
                                ms(c.latenciesSeconds.min() ?? 0), ms(c.latenciesSeconds.max() ?? 0),
                                pct(c.transcript.wer.rate)]))
            }
            if let l = r.short.latency {
                out.append("latency p50 \(ms(l.p50Seconds))  p90 \(ms(l.p90Seconds))  mean \(ms(l.meanSeconds))  "
                           + "max \(ms(l.maxSeconds))  (n=\(l.count))  ·  \(werSummary(r.short.wer))")
            }
        }

        if !r.long.clips.isEmpty {
            out.append("")
            out.append("Long audio")
            out.append(row(["clip", "audio", "time", "RTF", "speed", "WER"]))
            for c in r.long.clips {
                out.append(row([c.id, secs(c.audioSeconds, 0), secs(c.processingSeconds, 1),
                                String(format: "%.3f", c.realTimeFactor), speed(c.realTimeFactor),
                                pct(c.transcript.wer.rate)]))
            }
            if let rtf = r.long.realTimeFactor {
                out.append("RTF \(String(format: "%.3f", rtf)) (\(speed(rtf)) real time)  ·  \(werSummary(r.long.wer))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Clip id, then five right-aligned numbers.
    private static let columnWidths = [24, 8, 8, 8, 8, 7]

    private func row(_ cells: [String]) -> String {
        zip(cells, Self.columnWidths).enumerated().map { i, pair in
            let (cell, width) = pair
            let pad = String(repeating: " ", count: max(0, width - cell.count))
            return i == 0 ? cell + pad : pad + cell
        }.joined(separator: " ")
    }

    private func werSummary(_ wer: WordErrorRate) -> String {
        "WER \(pct(wer.rate)) (\(wer.errors)/\(wer.referenceWords) words)"
    }

    private func secs(_ s: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)fs", s) }
    private func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }
    private func pct(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }
    private func speed(_ rtf: Double) -> String { rtf > 0 ? String(format: "%.1fx", 1 / rtf) : "-" }
    private func mib(_ bytes: UInt64) -> String { String(format: "%.0f MiB", Double(bytes) / 1_048_576) }
    private func gib(_ bytes: UInt64) -> String { String(format: "%.0f GiB", Double(bytes) / 1_073_741_824) }
}

/// An optional that encodes as an explicit `null` instead of dropping its key
/// (Codable's default), so the report's key set never varies.
@propertyWrapper
struct NullWhenAbsent<Value: Codable & Equatable>: Codable, Equatable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}
