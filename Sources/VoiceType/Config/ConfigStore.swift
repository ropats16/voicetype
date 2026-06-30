import Foundation

/// Loads and persists `Config` as pretty-printed JSON. On first run it writes
/// the defaults so the user has a documented file to edit.
final class ConfigStore {
    private(set) var config: Config
    private let url: URL

    init(url: URL = Paths.configFile) {
        self.url = url
        self.config = ConfigStore.load(from: url)
    }

    /// Re-read from disk (used when the user edits the file manually).
    func reload() {
        config = ConfigStore.load(from: url)
    }

    func save() {
        Paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("Failed to write config: \(error.localizedDescription)")
        }
    }

    func update(_ mutate: (inout Config) -> Void) {
        mutate(&config)
        save()
    }

    private static func load(from url: URL) -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let store = ConfigStore.defaultsStore(at: url)
            return store
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.error("Config at \(url.path) is invalid (\(error.localizedDescription)); using defaults.")
            return .defaults
        }
    }

    /// Writes defaults to disk and returns them (first-run path).
    private static func defaultsStore(at url: URL) -> Config {
        Paths.ensureDirectories()
        let defaults = Config.defaults
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(defaults) {
            try? data.write(to: url, options: .atomic)
            Log.info("Wrote default config to \(url.path)")
        }
        return defaults
    }
}
