import Foundation

/// The whole clipboard at one moment: every item, and for each item every
/// type's raw data in the order the pasteboard listed them. Restoring it
/// reproduces the contents exactly — rich text, images, file URLs and private
/// app types included, not just the plain string.
///
/// Types whose data couldn't be read (e.g. an unresolvable promise) are left
/// out; an item with no readable type at all is dropped.
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
}
