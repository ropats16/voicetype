import Foundation

/// `VoiceType --bench --model <file> [options]`
///
/// Benchmarks a speech engine over the fixtures in a manifest (see
/// `scripts/fetch_bench_fixtures.sh`), through `TranscriptionEngine` exactly as
/// the app uses it. Prints a table to stdout and writes the full JSON report.
/// No network, no UI, no permissions.
enum BenchCommand {
    static let usage = """
    usage: VoiceType --bench --model <file> [--engine <id>] [--manifest <manifest.tsv>]
                     [--runs <n>] [--only short|long] [--json <out.json>] [--git-sha <sha>]

      --model     model file for the engine (e.g. ggml-tiny.en.bin)
      --engine    engine to bench: \(BenchEngine.all.map(\.id).joined(separator: ", ")) (default: whisper)
      --manifest  fixture list (default: .bench/fixtures/manifest.tsv)
      --runs      passes over the short clips (default: 3)
      --only      bench just the short or just the long clips
      --json      where to write the report
                  (default: .bench/results/<time>-<engine>-<model>.json)
      --git-sha   commit to record (default: from git, if run inside the repo)

    """

    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? { CommandLineSupport.value(flag, in: arguments) }
        guard let model = value("--model") else { return fail(usage, code: 2) }
        let engineID = value("--engine") ?? "whisper"
        guard let engine = BenchEngine.named(engineID) else {
            return fail("unknown engine '\(engineID)'\n\n\(usage)", code: 2)
        }
        let runs = value("--runs").map { Int($0) ?? 0 } ?? 3
        guard runs > 0 else { return fail("--runs must be a positive integer", code: 2) }
        let only = value("--only").flatMap(BenchClip.Kind.init(rawValue:))
        if value("--only") != nil && only == nil { return fail("--only must be short or long", code: 2) }
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

            let machine = MachineInfo.current()
            log("Benching \(engine.id) with \(modelURL.lastPathComponent) on \(machine.chip)"
                + " (\(clips.filter { $0.kind == .short }.count) short × \(runs), "
                + "\(clips.filter { $0.kind == .long }.count) long)")
            let runner = BenchRunner(engine: engine, modelPath: modelURL.path, shortRuns: runs)
            let results = try CommandLineSupport.blocking { try await runner.run(clips) }

            let modelBytes = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            let report = BenchReport(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                machine: machine,
                engine: .init(id: engine.id, modelFile: modelURL.lastPathComponent, modelBytes: modelBytes),
                build: .init(configuration: buildConfiguration, gitSHA: value("--git-sha") ?? MachineInfo.gitSHA()),
                settings: .init(shortRuns: runs),
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
    static func current() -> BenchReport.Machine {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BenchReport.Machine(
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            model: sysctlString("hw.model") ?? "unknown",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                + (sysctlString("kern.osversion").map { " (\($0))" } ?? ""),
            thermalState: thermal)
    }

    /// The current directory's git commit, with "-dirty" for uncommitted
    /// tracked changes; nil outside a repo or without git.
    static func gitSHA() -> String? {
        guard let sha = git(["rev-parse", "--short=12", "HEAD"]), !sha.isEmpty else { return nil }
        let dirty = !(git(["status", "--porcelain", "--untracked-files=no"]) ?? "").isEmpty
        return sha + (dirty ? "-dirty" : "")
    }

    private static func git(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
