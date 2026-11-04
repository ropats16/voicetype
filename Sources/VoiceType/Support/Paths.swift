import Foundation

/// Resolves the on-disk locations the app reads and writes.
///
/// Everything lives under `~/Library/Application Support/VoiceType/` so that a
/// `.app` installed to `/Applications` and a `swift run` dev build share the
/// same config and downloaded models.
///
/// One override rule, shared with `scripts/download_model.sh` and
/// `scripts/setup.sh`: a non-empty `VOICETYPE_APP_SUPPORT` environment variable
/// replaces that base folder (models then live in `$VOICETYPE_APP_SUPPORT/models`).
/// A `config.json` `modelPath` still points at one specific file.
enum Paths {
    /// The environment variable that relocates the support folder.
    static let overrideVariable = "VOICETYPE_APP_SUPPORT"

    /// `~/Library/Application Support/VoiceType/`, or `$VOICETYPE_APP_SUPPORT`.
    static var appSupportDir: URL { appSupportDir(environment: ProcessInfo.processInfo.environment) }

    static func appSupportDir(environment: [String: String]) -> URL {
        if let override = environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
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

    /// `.../VoiceType/model-checksums.json` — verified-file cache (see `ModelVerifier`).
    static var checksumCacheFile: URL {
        appSupportDir.appendingPathComponent("model-checksums.json", isDirectory: false)
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
