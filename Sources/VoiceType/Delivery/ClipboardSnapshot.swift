import Foundation

/// The whole clipboard at one moment: every item, and for each item every
/// type's raw data in the order the pasteboard listed them. Restoring it
/// reproduces the contents exactly — rich text, images, file URLs and private
/// app types included, not just the plain string.
///
/// What's left out (see `captures(type:)`):
/// - file promises: their data is a promise to write a file on demand, which
///   can't be honoured once restored, and reading it may make the source app
///   do the work;
/// - types whose data couldn't be read (an unresolvable lazy item); an item
///   with no readable type at all is dropped.
/// Any other lazily provided type is forced (read) at snapshot time.
struct ClipboardSnapshot: Equatable {
    /// One type's data, keyed by its UTI string (e.g. `public.utf8-plain-text`).
    struct Representation: Equatable {
        let type: String
        let data: Data
    }

    /// One pasteboard item.
    struct Item: Equatable {
        let representations: [Representation]
        init(_ representations: [Representation]) { self.representations = representations }
    }

    let items: [Item]

    /// An empty clipboard.
    static let empty = ClipboardSnapshot(items: [])

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Markers (nspasteboard.org)

    /// "Temporary contents, e.g. a clipboard auto-restore": set on our paste
    /// writes so clipboard managers skip them.
    static let transientType = "org.nspasteboard.TransientType"

    /// Types whose owner wants the contents gone soon: password managers'
    /// concealed copies (1Password also sets its own type) and transient
    /// writes. Restoring one would outlive the owner's auto-clear.
    static let ephemeralTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", transientType, "com.agilebits.onepassword",
    ]

    /// Some item carries an ephemeral marker: never put it back.
    var isEphemeral: Bool {
        items.contains { $0.representations.contains { Self.ephemeralTypes.contains($0.type) } }
    }

    // MARK: - Promises

    /// File-promise types, as `NSFilePromiseProvider` and the legacy
    /// `NSFilesPromisePboardType` write them.
    static let filePromiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.NSFilePromiseID",
        "Apple files promise pasteboard type",
    ]

    /// Whether a snapshot reads and keeps `type`. File promises
    /// (`com.apple.pasteboard.promised-*` and `filePromiseTypes`) are skipped.
    static func captures(type: String) -> Bool {
        !type.hasPrefix("com.apple.pasteboard.promised-") && !filePromiseTypes.contains(type)
    }
}
