import Foundation

/// `VoiceType --bench --model <file> [options]`
///
/// Benchmarks a speech engine over the fixtures in a manifest (see
/// `scripts/fetch_bench_fixtures.sh`), through `TranscriptionEngine` exactly as
/// the app uses it. Prints a table to stdout and writes the full JSON report.
/// No network, no UI, no permissions, and nothing written but the report.
enum BenchCommand {
    static func usage(_ config: Config) -> String {
        """
        usage: VoiceType --bench --model <file> [--engine <id>] [--manifest <manifest.tsv>]
                         [--runs <n>] [--only short|long] [--language <code>] [--threads <n>]
                         [--json <out.json>] [--git-sha <sha>]

          --model     model file (or directory) for the engine (e.g. ggml-tiny.en.bin)
          --engine    engine to bench: \(engineIDs) (default: whisper)
          --manifest  fixture list (default: .bench/fixtures/manifest.tsv)
          --runs      passes over the short clips (default: 3)
          --only      bench just the short or just the long clips
          --language  transcription language (default: config.json's, now "\(config.language)")
          --threads   engine threads, 0 = auto (default: config.json's, now \(config.threads))
          --json      where to write the report
                      (default: .bench/results/<time>-<engine>-<model>.json)
          --git-sha   commit to record, e.g. --git-sha "$(git describe --always --dirty)"

        """
    }

    private static var engineIDs: String {
        BenchEngine.all(.init(language: "en", threads: 0)).map(\.id).joined(separator: ", ")
    }

    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? { CommandLineSupport.value(flag, in: arguments) }
        let config = readConfig()
        guard let model = value("--model") else { return fail(usage(config), code: 2) }

        let threads = value("--threads").map { Int($0) ?? -1 } ?? config.threads
        guard threads >= 0 else { return fail("--threads must be a non-negative integer", code: 2) }
        let options = BenchEngine.Options(language: value("--language") ?? config.language, threads: threads)
        let engineID = value("--engine") ?? "whisper"
        guard let engine = BenchEngine.named(engineID, options) else {
            return fail("unknown engine '\(engineID)'\n\n\(usage(config))", code: 2)
        }
        let runs = value("--runs").map { Int($0) ?? 0 } ?? 3
        guard runs > 0 else { return fail("--runs must be a positive integer", code: 2) }
        var only: BenchClip.Kind?
        if let raw = value("--only") {
            guard let kind = BenchClip.Kind(rawValue: raw) else { return fail("--only must be short or long", code: 2) }
            only = kind
        }
        let manifestURL = URL(fileURLWithPath: value("--manifest") ?? ".bench/fixtures/manifest.tsv")
        let modelURL = URL(fileURLWithPath: model)

        do {
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return fail("no manifest at \(manifestURL.path) — run scripts/fetch_bench_fixtures.sh first", code: 1)
            }
            let entries = try BenchManifest.load(manifestURL).filter { only == nil || $0.kind == only }
            log("Decoding \(entries.count) fixture\(entries.count == 1 ? "" : "s") from \(manifestURL.path)")
            let clips = try entries.map { entry in
                BenchClip(id: entry.id, kind: entry.kind, reference: entry.reference,
                          samples: try CommandLineSupport.samples(fromAudioFile: entry.file))
            }

            let thermalAtStart = MachineInfo.thermalState()
            log("Benching \(engine.id) with \(modelURL.lastPathComponent) (\(clips.of(.short).count) short × \(runs), "
                + "\(clips.of(.long).count) long; language \(options.language), threads \(options.threads))")
            let runner = BenchRunner(engine: engine, model: .file(modelURL.path, language: options.language),
                                     shortRuns: runs)
            let results = try CommandLineSupport.blocking { try await runner.run(clips) }

            let report = BenchReport(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                machine: MachineInfo.current(thermalAtStart: thermalAtStart),
                engine: .init(id: engine.id, modelFile: modelURL.lastPathComponent, modelBytes: diskSize(of: modelURL)),
                build: .init(configuration: buildConfiguration, gitSHA: value("--git-sha")),
                settings: .init(shortRuns: runs, language: options.language, threads: options.threads),
                results: results)

            let jsonURL = URL(fileURLWithPath: value("--json") ?? defaultJSONPath(engine: engine.id, model: modelURL))
            try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try report.jsonData().write(to: jsonURL)
            print(report.table(), terminator: "")
            log("Wrote \(jsonURL.path)")
            return 0
        } catch {
            return fail("bench failed: \(error.localizedDescription)", code: 1)
        }
    }

    /// The user's config, read-only (unlike `ConfigStore`, never writes
    /// defaults); defaults if there's none or it doesn't decode.
    private static func readConfig() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return .defaults }
        return config
    }

    /// A file's size, or the total of a directory's files (e.g. a CoreML
    /// `.mlmodelc`); nil if nothing is there.
    static func diskSize(of url: URL) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) }
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var total: UInt64 = 0
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func defaultJSONPath(engine: String, model: URL) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return ".bench/results/\(stamp.string(from: Date()))-\(engine)-\(model.deletingPathExtension().lastPathComponent).json"
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("[bench] \(s)\n".utf8))
    }

    private static func fail(_ s: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("\(s)\n".utf8))
        return code
    }
}

/// What the report records about the Mac it ran on, so runs compare across
/// machines.
enum MachineInfo {
    static func current(thermalAtStart: String) -> BenchReport.Machine {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BenchReport.Machine(
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            model: sysctlString("hw.model") ?? "unknown",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                + (sysctlString("kern.osversion").map { " (\($0))" } ?? ""),
            thermalStateAtStart: thermalAtStart,
            thermalStateAtEnd: thermalState())
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
