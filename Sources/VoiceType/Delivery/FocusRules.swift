import Foundation

/// Where a ⌘V would land, as far as Accessibility can tell.
enum FocusVerdict: Equatable {
    /// An editable text element is focused: paste.
    case editable
    /// Something non-editable is focused: copy and tell the user.
    case notEditable
    /// The app exposed nothing (or didn't answer). Pasted anyway: silently
    /// swallowing a dictation is worse than a best-effort ⌘V, and Electron
    /// apps often expose no focused element even when a field has the caret.
    case unknown
}

/// The verdict plus how long the app may take to read the pasteboard.
struct FocusReport: Equatable {
    let verdict: FocusVerdict
    /// The app may read the pasteboard late: restore on `ClipboardPaster.Timing.slowApp`.
    let isSlowApp: Bool
}

/// The pure rules from a `FocusObservation` to a `FocusReport`.
enum FocusRules {
    /// Standard AX roles for editable text controls.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static let finderBundleID = "com.apple.finder"

    static func report(for observation: FocusObservation) -> FocusReport {
        FocusReport(verdict: verdict(for: observation),
                    // A timed-out app is busy: it may read the pasteboard late too.
                    isSlowApp: observation.isChromiumHosted || observation.focused == .timedOut)
    }

    /// - A focused element is editable when its role is a text control or its
    ///   value is settable; otherwise not.
    /// - No element / a timeout is `.unknown` (pasted), except in Finder.
    ///   Finder is native and always exposes its text fields (rename, search,
    ///   Go to Folder), so nothing editable there means the desktop or a file
    ///   list: copy with the notice instead of ⌘V-pasting files.
    static func verdict(for observation: FocusObservation) -> FocusVerdict {
        switch observation.focused {
        case .element(let role, let valueSettable):
            if let role, editableRoles.contains(role) { return .editable }
            return valueSettable ? .editable : .notEditable
        case .none, .timedOut:
            return observation.bundleID == finderBundleID ? .notEditable : .unknown
        }
    }
}
