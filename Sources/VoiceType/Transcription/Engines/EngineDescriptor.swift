import Foundation

/// Everything the app needs to know about one speech engine, in one place:
/// whether this Mac can run it, which languages it takes, how the user's model
/// choice becomes a `ModelSpec`, whether that model is installed (and how to
/// get it if not), how to build its adapter, and whom to credit.
///
/// Adding an engine is one file with a conforming type plus one line in
/// `EngineRegistry.shared`; config, Settings, the model-missing notices, the
/// bench and `--selftest` all pick it up from here. Only `kind`, `resolve`,
/// `makeAdapter` and `acknowledgement` are required — the rest default to "a
/// model is a file or directory at `spec.path`, any language, any Mac".
///
/// Descriptors are plain values, consulted from any thread; keep them free of
/// mutable state. Model loading belongs in the adapter, which the engine only
/// ever builds and calls on its own queue.
protocol EngineDescriptor {
    var kind: EngineKind { get }

    /// Whether this Mac can run the engine (OS version, chip). Default: always.
    func availability(in environment: EngineEnvironment) -> EngineAvailability

    /// Lowercase ISO codes the engine transcribes, nil = any language. Include
    /// `ModelSpec.autoDetect` ("auto") if it can detect the language itself;
    /// otherwise Settings' Auto-detect falls back to whisper. Default: nil.
    var supportedLanguages: Set<String>? { get }

    /// The models Settings offers for this engine, in display order; a
    /// `ModelChoice.named` id is one of these ids. Default: none (the engine
    /// only has Automatic).
    var models: [EngineModelOption] { get }

    /// The model to load for `choice`. Pure: what's on disk comes in
    /// `context`. `.named` ids not in `models` (hand-edited config) should
    /// still resolve, and the engine then reports `.missing` or `.failed`.
    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec

    /// The ids of `models` that are installed, for Settings' downloaded / not
    /// downloaded split. Default: those whose resolved spec `isPresent`.
    func installedModelIDs(in context: ModelContext) -> Set<String>

    /// Whether `spec`'s model is installed, so the engine can report
    /// `.missing` (not `.failed`) without trying a load. Default: a file or
    /// directory exists at `spec.path`. OS-managed engines override it, and
    /// may block to ask the OS: the engine calls it on its queue, never main.
    func isPresent(_ spec: ModelSpec) -> Bool

    /// How the user gets `spec`'s model when it's missing (menu line, notice,
    /// Settings); nil when there's nothing useful to say. Default: nil.
    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint?

    /// What Settings' Download button fetches for model `id` of `models`
    /// into `modelsDir`; nil when the app can't download it itself (the
    /// model comes by command, or the OS manages it). Default: nil.
    func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload?

    /// Whether a model's first load on this Mac (and after a macOS update)
    /// compiles it, so it's much slower than later ones: Core ML engines
    /// specialize the model for this chip's Neural Engine. Readiness and
    /// Settings then say so (`EngineRegistry.isFirstLoad`). Default: false.
    var compilesOnFirstLoad: Bool { get }

    /// The spec for a model named on the command line (`--bench --model`,
    /// `--selftest --model`): a path, or whatever the engine takes there.
    /// Default: an unverified spec for that path.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec

    /// The model → adapter factory `TranscriptionEngine` loads with. It runs
    /// on the engine's queue, after `isPresent` and any checksum passed;
    /// throwing reports `.failed` (and keeps the previous model loaded).
    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter

    /// A credit for the engine and its models (name, author, license), for
    /// the Acknowledgements screen. Keep it in step with its section in
    /// `ACKNOWLEDGEMENTS.md` (`AcknowledgementsTests` checks the heading).
    var acknowledgement: String { get }
}

extension EngineDescriptor {
    func availability(in environment: EngineEnvironment) -> EngineAvailability { .available }
    var supportedLanguages: Set<String>? { nil }
    var models: [EngineModelOption] { [] }
    var compilesOnFirstLoad: Bool { false }

    func installedModelIDs(in context: ModelContext) -> Set<String> {
        Set(models.filter { isPresent(resolve(.named($0.id), in: context)) }.map(\.id))
    }

    func isPresent(_ spec: ModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: spec.path)   // true for directories too
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? { nil }

    func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload? { nil }

    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        ModelSpec(path: (argument as NSString).expandingTildeInPath, sha256: nil,
                  language: ModelSpec.language(language), engine: kind)
    }

    /// Whether the engine transcribes `language` (an ISO code or "auto").
    func supports(language: String) -> Bool {
        supportedLanguages.map { $0.contains(language.lowercased()) } ?? true
    }
}

/// The facts about this Mac that engine availability depends on. Injected so
/// the OS and chip gates are testable.
struct EngineEnvironment: Equatable {
    var macOSMajor: Int
    var macOSMinor: Int
    var hardware: HardwareProfile

    static var current: EngineEnvironment {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return EngineEnvironment(macOSMajor: os.majorVersion, macOSMinor: os.minorVersion, hardware: .current)
    }

    func isAtLeast(macOS major: Int, _ minor: Int = 0) -> Bool {
        (macOSMajor, macOSMinor) >= (major, minor)
    }
}

enum EngineAvailability: Equatable {
    case available
    /// `reason` completes "Using Whisper because …", e.g. "Apple Speech needs
    /// macOS 26".
    case unavailable(reason: String)
}

/// The app settings adapters are built with, from `Config` (or the bench's
/// flags). The language isn't here: it's in `ModelSpec`, since changing it
/// reloads the model.
struct EngineOptions: Equatable {
    /// 0 = the engine's own default.
    var threads: Int = 0
    /// whisper.cpp knobs; other engines ignore them.
    var whisper: WhisperTuning = .default
}

/// What resolving a model choice may look at. Pure data, so resolution is
/// testable without a models folder.
struct ModelContext {
    /// An ISO code or `ModelSpec.autoDetect`.
    var language: String
    var hardware: HardwareProfile
    /// Where the app keeps downloaded models (`Paths.modelsDir`). An engine
    /// may use a subfolder of it.
    var modelsDir: URL
    /// The finished files and folders at the top level of `modelsDir`.
    var presentFilenames: Set<String>
    /// `config.json`'s `modelPath`: a hand-set model file overriding the
    /// choice. Only whisper reads it.
    var customPath: String = ""
}

/// One row of an engine's model picker.
struct EngineModelOption: Hashable, Identifiable {
    /// What `ModelChoice.named` (`engineModels` in `config.json`) stores.
    let id: String
    /// e.g. "small.en-q5_1 (190 MB)".
    let label: String
}

/// How the user gets a model that isn't installed.
enum ModelDownloadHint: Equatable {
    /// A command to run in the repo, e.g. `make model MODEL=small.en-q5_1`.
    case command(String)
    /// Settings' Download button fetches it (`EngineDescriptor.inAppDownload`);
    /// `command` fetches the same files from the repo, e.g. `make
    /// whisperkit-model WHISPERKIT=tiny.en`.
    case inApp(command: String)
    /// A sentence, for engines whose models aren't fetched by a command, e.g.
    /// "Open Settings › Model to download it."
    case instructions(String)
}
