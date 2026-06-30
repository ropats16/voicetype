import Foundation

/// Resolves the on-disk locations the app reads and writes.
///
/// Everything lives under `~/Library/Application Support/VoiceType/` so that a
/// `.app` installed to `/Applications` and a `swift run` dev build share the
/// same config and downloaded models.
enum Paths {
    /// `~/Library/Application Support/VoiceType/`
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// `.../VoiceType/models/`
    static var modelsDir: URL {
        appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    /// `.../VoiceType/config.json`
    static var configFile: URL {
        appSupportDir.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `.../VoiceType/models/ggml-medium.en.bin`
    static var defaultModelFile: URL {
        modelsDir.appendingPathComponent(AppInfo.defaultModelFilename, isDirectory: false)
    }

    /// Create the support + models directories if they do not yet exist.
    @discardableResult
    static func ensureDirectories() -> Bool {
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            return true
        } catch {
            Log.error("Failed to create support directories: \(error.localizedDescription)")
            return false
        }
    }
}
