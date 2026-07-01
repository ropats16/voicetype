import Foundation

/// A single entry in the model catalog.
struct ModelCatalogEntry: Equatable {
    let size: String
    let filename: String
    let isDownloaded: Bool
}

/// Static catalog of known Whisper model sizes with pure helpers for
/// presence checking and path resolution. No filesystem access inside —
/// callers supply the set of present filenames so tests stay hardware-free.
enum ModelCatalog {

    /// Known model sizes in ascending order (smallest → largest).
    static let sizes = ["tiny.en", "base.en", "small.en", "medium.en"]

    /// Returns the expected on-disk filename for a given size, e.g. "ggml-small.en.bin".
    static func filename(for size: String) -> String {
        "ggml-\(size).bin"
    }

    /// Builds the full catalog ordered by `sizes`, marking each entry downloaded
    /// if its filename appears in `presentFilenames`.
    static func entries(presentFilenames: Set<String>) -> [ModelCatalogEntry] {
        sizes.map { size in
            let fn = filename(for: size)
            return ModelCatalogEntry(size: size, filename: fn,
                                     isDownloaded: presentFilenames.contains(fn))
        }
    }

    /// Returns the catalog size string whose filename matches the last path
    /// component of `modelPath`, or `nil` if the path doesn't match any known size.
    static func selectedSize(modelPath: String) -> String? {
        guard !modelPath.isEmpty else { return nil }
        let lastComponent = URL(fileURLWithPath: modelPath).lastPathComponent
        return sizes.first { filename(for: $0) == lastComponent }
    }
}
