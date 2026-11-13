import Foundation

/// Parakeet TDT v3 (via FluidAudio) as an `EngineDescriptor`: the opt-in
/// "Turbo (English/EU)" engine. Apple Silicon only (it runs on the Neural
/// Engine) and only for its 25 European languages, picked explicitly. A model is a folder,
/// `<models>/parakeet/<id>`, fetched by Settings' Download button or `make parakeet-model` and verified
/// against its pinned manifest before loading (`FolderModelEngine`).
struct ParakeetEngine: FolderModelEngine {
    typealias Catalog = ParakeetCatalog
    let kind = EngineKind.parakeet

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        environment.hardware.isAppleSilicon ? .available : .unavailable(reason: "Turbo needs Apple Silicon")
    }

    /// The catalog's languages, without auto-detect: v3 only detects among
    /// its own languages, so under Auto-detect a speaker of any other one
    /// would get confident garbage. Auto-detect falls back to whisper (with
    /// Settings' "Using Whisper because …" note) until a language is picked.
    var supportedLanguages: Set<String>? {
        Set(ParakeetCatalog.models.flatMap(\.languages))
    }

    func automaticModel(in context: ModelContext) -> ParakeetModel {
        ParakeetCatalog.defaultModel
    }

    func downloadCommand(for model: ParakeetModel) -> String {
        model == ParakeetCatalog.defaultModel ? "make parakeet-model" : "make parakeet-model PARAKEET=\(model.id)"
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.parakeetAdapter()
    }

    let acknowledgement = """
        Parakeet TDT 0.6B v3 by NVIDIA (CC BY 4.0), converted to Core ML by FluidInference. \
        FluidAudio by FluidInference (Apache 2.0).
        """
}
