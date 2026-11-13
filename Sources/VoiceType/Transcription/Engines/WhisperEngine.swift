import Foundation

/// whisper.cpp as an `EngineDescriptor`: the existing catalog, auto-pick,
/// checksums and `make model` hints, unchanged. Runs on every Mac (Metal on
/// Apple Silicon, CPU on Intel) and every language, so it's the fallback.
struct WhisperEngine: EngineDescriptor {
    let kind = EngineKind.whisper

    var models: [EngineModelOption] {
        ModelCatalog.models.map { EngineModelOption(id: $0.id, label: $0.label) }
    }

    /// `ModelSelection.resolve(model:modelPath:…)`: a hand-set `modelPath`,
    /// else the named model, else the hardware auto-pick.
    func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
        ModelSelection.resolve(model: choice, modelPath: context.customPath, language: context.language,
                               hardware: context.hardware, modelsDir: context.modelsDir,
                               presentFilenames: context.presentFilenames)
    }

    /// Catalog files in the models folder, by name (no per-model stat).
    func installedModelIDs(in context: ModelContext) -> Set<String> {
        Set(ModelCatalog.models.filter { context.presentFilenames.contains($0.filename) }.map(\.id))
    }

    func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
        ModelSelection.downloadCommand(for: spec).map(ModelDownloadHint.command)
    }

    /// Verified against the catalog checksum when it's a catalog file.
    func spec(forModelArgument argument: String, language: String) -> ModelSpec {
        .file(argument, language: language)
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.whisperAdapter(threads: options.threads, tuning: options.whisper)
    }

    let acknowledgement = """
        whisper.cpp and ggml by Georgi Gerganov and contributors (MIT). \
        Whisper models by OpenAI (MIT), in ggml format from huggingface.co/ggerganov/whisper.cpp.
        """
}
