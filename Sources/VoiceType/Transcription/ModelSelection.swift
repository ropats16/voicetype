import Foundation

/// Turns the user's model settings into what the engine loads, and decides
/// whether the model stays resident. Pure: hardware and the models folder's
/// contents are injected.
enum ModelSelection {
    /// The `model` value meaning "pick for this Mac".
    static let automatic = "auto"

    /// Precedence: an explicit `modelPath` (any file; verified if its name is a
    /// catalog file), else an explicit catalog `model` id (even if not yet
    /// downloaded — the engine then reports `.missing`), else the auto-pick.
    ///
    /// The auto-pick never asks for a download: if the recommended model isn't
    /// present it uses the largest downloaded catalog model no bigger than it
    /// (the smallest one if none is), so a Mac set up with an older default
    /// keeps working. With nothing downloaded it names the recommended model.
    ///
    /// English-only models always decode as "en"; a blank language is "auto".
    static func resolve(model: String, modelPath: String, language: String,
                        hardware: HardwareProfile, modelsDir: URL,
                        presentFilenames: Set<String>) -> ModelSpec {
        let language = language.isEmpty ? "auto" : language

        if !modelPath.isEmpty {
            let path = (modelPath as NSString).expandingTildeInPath
            let known = ModelCatalog.model(forFile: path)
            let englishOnly = known?.isEnglishOnly ?? URL(fileURLWithPath: path).lastPathComponent.contains(".en")
            return ModelSpec(path: path, sha256: known?.sha256, language: englishOnly ? "en" : language)
        }

        if model != automatic, !model.isEmpty {
            guard let known = ModelCatalog.model(id: model) else {
                // A model the catalog doesn't pin (e.g. large-v1): load it unverified.
                let path = modelsDir.appendingPathComponent("ggml-\(model).bin").path
                return ModelSpec(path: path, sha256: nil, language: model.contains(".en") ? "en" : language)
            }
            return spec(for: known, in: modelsDir, language: language)
        }

        let recommended = ModelCatalog.recommended(for: hardware, language: language)
        let usable = ModelCatalog.models.filter {
            presentFilenames.contains($0.filename) && (ModelCatalog.isEnglish(language) || !$0.isEnglishOnly)
        }
        let chosen = usable.contains(recommended) ? recommended
            : usable.filter { $0.bytes <= recommended.bytes }.max { $0.bytes < $1.bytes }
            ?? usable.min { $0.bytes < $1.bytes }
            ?? recommended
        return spec(for: chosen, in: modelsDir, language: language)
    }

    /// Convenience over `resolve` for the app's config.
    static func resolve(_ config: Config, hardware: HardwareProfile = .current,
                        modelsDir: URL = Paths.modelsDir,
                        presentFilenames: Set<String>) -> ModelSpec {
        resolve(model: config.model, modelPath: config.modelPath, language: config.language,
                hardware: hardware, modelsDir: modelsDir, presentFilenames: presentFilenames)
    }

    /// How long the engine waits idle before unloading the model, or nil to
    /// keep it loaded. `keepWarm` nil = automatic: keep it loaded unless the
    /// Mac has 8 GB or less, where the RAM is worth more than the ~1 s reload.
    static func idleUnloadAfter(keepWarm: Bool?, idleMinutes: Double,
                                hardware: HardwareProfile) -> TimeInterval? {
        let warm = keepWarm ?? (hardware.memoryGiB > 8)
        return warm ? nil : max(1, idleMinutes) * 60
    }

    /// The files in the models folder, for `presentFilenames`.
    static func presentFilenames(in dir: URL = Paths.modelsDir) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private static func spec(for model: WhisperModel, in dir: URL, language: String) -> ModelSpec {
        ModelSpec(path: dir.appendingPathComponent(model.filename).path,
                  sha256: model.sha256,
                  language: model.isEnglishOnly ? "en" : language)
    }
}
