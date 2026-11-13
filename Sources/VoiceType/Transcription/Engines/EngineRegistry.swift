import Foundation

/// The engines this build can run, and the rules for picking one. The app,
/// Settings, config validation and the bench all go through `shared`; tests
/// build their own with fake descriptors.
struct EngineRegistry {

    /// Every engine in this build. To add one, write its `EngineDescriptor`
    /// (see `WhisperEngine`) and add one line here. Order is Settings' order.
    static let shared = EngineRegistry([
        WhisperEngine(),
        WhisperKitEngine(),
        ParakeetEngine(),
        AppleSpeechEngine(),
    ])

    /// In registration order; whisper is always among them.
    let descriptors: [any EngineDescriptor]

    /// `descriptors` must include whisper (the fallback), once per kind.
    init(_ descriptors: [any EngineDescriptor]) {
        precondition(descriptors.contains { $0.kind == .whisper }, "whisper is the fallback engine; register it")
        precondition(Set(descriptors.map(\.kind)).count == descriptors.count, "an engine is registered twice")
        self.descriptors = descriptors
    }

    func descriptor(for kind: EngineKind) -> (any EngineDescriptor)? {
        descriptors.first { $0.kind == kind }
    }

    /// The fallback engine.
    var whisper: any EngineDescriptor { descriptor(for: .whisper)! }

    /// Whether `kind` can run here: registered, and its own gate passes.
    func availability(of kind: EngineKind, in environment: EngineEnvironment) -> EngineAvailability {
        guard let descriptor = descriptor(for: kind) else {
            return .unavailable(reason: "\(kind.displayName) isn't in this build")
        }
        return descriptor.availability(in: environment)
    }

    /// Whether the engine `id` names can run here (`config.json`'s `engine`,
    /// `--bench --engine`); `reason` says why not.
    func availability(ofID id: String, in environment: EngineEnvironment) -> EngineAvailability {
        guard let kind = EngineKind(rawValue: id) else {
            return .unavailable(reason: "\"\(id)\" isn't a known engine")
        }
        return availability(of: kind, in: environment)
    }

    /// The engines Settings offers: runnable here and, when `language` is
    /// given, able to transcribe it. Always includes whisper.
    func available(in environment: EngineEnvironment, language: String? = nil) -> [EngineKind] {
        descriptors.filter {
            $0.availability(in: environment) == .available && language.map($0.supports(language:)) ?? true
        }.map(\.kind)
    }

    /// The engine to run for the configured `engineID` and `language`: that
    /// engine if it's registered, available here and takes the language,
    /// else whisper with the reason (for Settings' "Using Whisper because …"
    /// and the log). Never rewrites the config, so the choice comes back by
    /// itself when its reason goes away (e.g. the language changes back).
    func select(engineID: String, language: String, in environment: EngineEnvironment) -> EngineSelection {
        if case .unavailable(let reason) = availability(ofID: engineID, in: environment) {
            return EngineSelection(kind: .whisper, fallbackReason: reason)
        }
        let descriptor = descriptor(for: EngineKind(rawValue: engineID)!)!
        guard descriptor.supports(language: language) else {
            return EngineSelection(kind: .whisper,
                                   fallbackReason: "\(descriptor.kind.displayName) doesn't support \(Self.languageName(language))")
        }
        return EngineSelection(kind: descriptor.kind, fallbackReason: nil)
    }

    // MARK: - Per-spec dispatch (what `TranscriptionEngine` and the readiness hints use)

    /// Whether `spec`'s model is installed, by its engine's rule. False for an
    /// engine this build lacks.
    func isPresent(_ spec: ModelSpec) -> Bool {
        descriptor(for: spec.engine)?.isPresent(spec) ?? false
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        descriptor(for: spec.engine)?.downloadHint(for: spec)
    }

    /// One factory over every registered engine: each spec is loaded by its
    /// own engine's adapter, so switching engine is just switching model.
    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        let factories = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.kind, $0.makeAdapter(options)) })
        return { spec in
            guard let make = factories[spec.engine] else { throw EngineNotInBuild(kind: spec.engine) }
            return try make(spec)
        }
    }

    /// "Japanese", "auto-detect", or the code itself if unknown.
    static func languageName(_ code: String) -> String {
        if code == ModelSpec.autoDetect { return "auto-detect" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

/// Which engine runs, and why it isn't the configured one when it isn't.
struct EngineSelection: Equatable {
    let kind: EngineKind
    /// Completes "Using Whisper because …"; nil when the configured engine runs.
    let fallbackReason: String?
}

/// A spec names an engine this build has no descriptor for.
struct EngineNotInBuild: LocalizedError {
    let kind: EngineKind
    var errorDescription: String? { "\(kind.displayName) isn't in this build." }
}

extension TranscriptionEngine {
    /// The app's engine: each `ModelSpec` loads through its own engine's
    /// adapter (`EngineRegistry.makeAdapter`), so Settings switches engine
    /// live with `switchModel(to:)`, and `.missing` follows that engine's
    /// `isPresent`.
    static func registered(model: ModelSpec, options: EngineOptions, engines: EngineRegistry = .shared,
                           idleUnloadAfter: TimeInterval? = nil) -> TranscriptionEngine {
        TranscriptionEngine(model: model, idleUnloadAfter: idleUnloadAfter, isPresent: engines.isPresent,
                            makeAdapter: engines.makeAdapter(options))
    }
}
