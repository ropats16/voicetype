import Foundation

/// WhisperKit (Core ML; encoder and decoder on the Neural Engine) as an
/// `EngineDescriptor`. Apple Silicon only (Intel has no Neural Engine; Core
/// ML would fall back to the CPU). Any language whisper takes, auto-detect
/// included, with a multilingual model. A model is a folder,
/// `<models>/whisperkit/<id>`, fetched by `make whisperkit-model` and
/// verified against its pinned manifest before loading (`FolderModelEngine`).
struct WhisperKitEngine: FolderModelEngine {
    typealias Catalog = WhisperKitCatalog
    let kind = EngineKind.whisperKit

    func availability(in environment: EngineEnvironment) -> EngineAvailability {
        environment.hardware.isAppleSilicon ? .available : .unavailable(reason: "WhisperKit needs Apple Silicon")
    }

    func automaticModel(in context: ModelContext) -> WhisperKitModel {
        WhisperKitCatalog.defaultModel(language: context.language, hardware: context.hardware)
    }

    func downloadCommand(for model: WhisperKitModel) -> String {
        "make whisperkit-model WHISPERKIT=\(model.id)"
    }

    func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
        TranscriptionEngine.whisperKitAdapter()
    }

    let acknowledgement = """
        WhisperKit by Argmax (MIT). Whisper models by OpenAI (MIT), converted to Core ML by Argmax \
        (huggingface.co/argmaxinc/whisperkit-coreml).
        """
}
