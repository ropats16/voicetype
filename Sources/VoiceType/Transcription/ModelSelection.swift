import Foundation

/// The `model` setting: pick for this Mac, or a named model. Stored in
/// `config.json` as `"auto"` or the model id.
enum ModelChoice: Equatable, Codable {
    case automatic
    /// A catalog id like `small.en-q5_1` (or another whisper.cpp model name,
    /// loaded unverified).
    case named(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw.isEmpty || raw == "auto" ? .automatic : .named(raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .automatic: try c.encode("auto")
        case .named(let id): try c.encode(id)
        }
    }
}

extension ModelSpec {
    /// The language value meaning "detect it per job".
    static let autoDetect = "auto"

    /// A language as given (config, `--language`): empty means auto-detect.
    static func language(_ given: String) -> String { given.isEmpty ? autoDetect : given }

    /// A specific model file, verified against the catalog checksum if its name
    /// is a catalog file. English-only models always decode English.
    static func file(_ path: String, language: String = "en") -> ModelSpec {
        let path = (path as NSString).expandingTildeInPath
        let language = Self.language(language)
        return ModelSpec(path: path, sha256: ModelCatalog.model(forFile: path)?.sha256,
                         language: ModelCatalog.isEnglishOnly(path) ? "en" : language)
    }
}

/// What Automatic (`EnginePolicy`) needs to know beyond the models folder.
struct EngineFacts {
    /// Whether `spec`'s model is installed. In the app it must not block:
    /// Apple Speech is answered from the last asset query
    /// (`SpeechModelPresence`), the rest by their own `isPresent` (a stat).
    var isPresent: (ModelSpec) -> Bool
    /// Engines whose model failed to load this session: Automatic skips them.
    var failed: Set<EngineKind> = []
}

/// Turns the user's model settings into what the engine loads, and decides
/// whether the model stays resident. Pure: hardware and the models folder's
/// contents are injected.
enum ModelSelection {

    /// Precedence: an explicit `modelPath` (any file; verified if its name is a
    /// catalog file), else a named `model` (even if not yet downloaded — the
    /// engine then reports `.missing`), else the auto-pick.
    ///
    /// The auto-pick never asks for a download: if the recommended model isn't
    /// present it uses the largest downloaded catalog model no bigger than it
    /// (the smallest one if none is), so a Mac set up with an older default
    /// keeps working. With nothing downloaded it names the recommended model.
    static func resolve(model: ModelChoice, modelPath: String, language: String,
                        hardware: HardwareProfile, modelsDir: URL,
                        presentFilenames: Set<String>) -> ModelSpec {
        if !modelPath.isEmpty {
            return .file(modelPath, language: language)
        }
        let file = { (id: String) in
            ModelSpec.file(modelsDir.appendingPathComponent(WhisperModel.filename(for: id)).path, language: language)
        }
        if case .named(let id) = model {
            return file(id)
        }

        let recommended = ModelCatalog.recommended(for: hardware, language: language)
        let usable = ModelCatalog.models.filter {
            presentFilenames.contains($0.filename) && (ModelCatalog.isEnglish(language) || !$0.isEnglishOnly)
        }
        let chosen = usable.contains(recommended) ? recommended
            : usable.filter { $0.bytes <= recommended.bytes }.max { $0.bytes < $1.bytes }
            ?? usable.min { $0.bytes < $1.bytes }
            ?? recommended
        return file(chosen.id)
    }

    /// What the app runs for a config: the engine it names if that can run
    /// here (else whisper), or Automatic's pick, and that engine's pick
    /// resolved to a `ModelSpec`.
    struct Selected: Equatable {
        let spec: ModelSpec
        /// Why the configured engine isn't the one running, or under
        /// Automatic why it isn't Turbo (completes "Using Whisper because
        /// …"); nil when it is.
        let fallbackReason: String?
        /// The config's `engine` is "auto" (`EnginePolicy` picked `spec.engine`).
        var isAutomatic = false

        /// "Using Whisper (whisper.cpp) because …", for Settings and the log.
        var note: String? {
            fallbackReason.map { "Using \(spec.engine.displayName) because \($0)." }
        }
    }

    /// The app's config → the engine and model to load. The engine comes from
    /// `EngineRegistry.select` (configured engine, or whisper with a reason),
    /// or for "auto" from `EnginePolicy` (only engines whose model `facts`
    /// says is installed; default: each engine's own `isPresent`, which may
    /// block for Apple Speech — the app passes non-blocking facts). Its
    /// descriptor resolves the pick (`Config.modelChoice(for:)`). Pure: the
    /// Mac, the registry and the models folder's contents are injected.
    static func select(_ config: Config, environment: EngineEnvironment = .current,
                       engines: EngineRegistry = .shared, modelsDir: URL = Paths.modelsDir,
                       presentFilenames: Set<String>, facts: EngineFacts? = nil) -> Selected {
        func spec(_ descriptor: any EngineDescriptor) -> ModelSpec {
            let context = ModelContext(language: config.language, hardware: environment.hardware,
                                       modelsDir: modelsDir, presentFilenames: presentFilenames,
                                       customPath: config.customModelPath(for: descriptor.kind))
            return descriptor.resolve(config.modelChoice(for: descriptor.kind), in: context)
        }

        guard config.engineChoice == .automatic else {
            let engine = engines.select(engineID: config.engine, language: config.language, in: environment)
            return Selected(spec: spec(engines.descriptor(for: engine.kind) ?? engines.whisper),
                            fallbackReason: engine.fallbackReason)
        }
        let facts = facts ?? EngineFacts(isPresent: engines.isPresent)
        let pick = EnginePolicy.automatic(
            language: config.language, environment: environment,
            isInstalled: { kind in engines.descriptor(for: kind).map { facts.isPresent(spec($0)) } ?? false },
            failed: facts.failed, engines: engines)
        return Selected(spec: spec(engines.descriptor(for: pick.kind) ?? engines.whisper),
                        fallbackReason: pick.reason, isAutomatic: true)
    }

    /// `select(...).spec` on this Mac's OS with `hardware`.
    static func resolve(_ config: Config, hardware: HardwareProfile = .current,
                        modelsDir: URL = Paths.modelsDir,
                        presentFilenames: Set<String>) -> ModelSpec {
        var environment = EngineEnvironment.current
        environment.hardware = hardware
        return select(config, environment: environment, modelsDir: modelsDir, presentFilenames: presentFilenames).spec
    }

    /// How long the engine waits idle before unloading the model, or nil to
    /// keep it loaded. `keepWarm` nil = automatic: keep it loaded unless the
    /// Mac has 8 GB or less, where the RAM is worth more than the ~1 s reload.
    static func idleUnloadAfter(keepWarm: Bool?, idleMinutes: Double,
                                hardware: HardwareProfile) -> TimeInterval? {
        isKeptWarm(keepWarm, hardware: hardware) ? nil : max(1, idleMinutes) * 60
    }

    /// The effective keep-warm setting (`keepWarm` nil = the automatic default).
    static func isKeptWarm(_ keepWarm: Bool?, hardware: HardwareProfile) -> Bool {
        keepWarm ?? (hardware.memoryGiB > 8)
    }

    /// The command that downloads `spec`'s file — only when it is a catalog
    /// model in the models folder, where `make model` puts it. Nil for custom
    /// files and models the catalog doesn't pin.
    static func downloadCommand(for spec: ModelSpec, modelsDir: URL = Paths.modelsDir) -> String? {
        guard let model = ModelCatalog.model(forFile: spec.path),
              spec.path == modelsDir.appendingPathComponent(model.filename).path else { return nil }
        return "make model MODEL=\(model.id)"
    }

    /// The finished files in the models folder, for `presentFilenames`
    /// (in-progress `.part` downloads don't count).
    static func presentFilenames(in dir: URL = Paths.modelsDir) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { !$0.hasSuffix(".part") })
    }
}
