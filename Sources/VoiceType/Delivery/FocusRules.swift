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
    /// Restore the clipboard late (`ClipboardPaster.Timing.slowAppRestoreDelay`).
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

    /// Whether an app bundle whose `Contents/Frameworks` holds `frameworks` is
    /// Chromium-hosted. Electron ships `Electron Framework.framework`, CEF apps
    /// `Chromium Embedded Framework.framework`, and Chrome-family browsers
    /// `<Browser> Framework.framework` (Google Chrome, Microsoft Edge, Brave,
    /// …) — all the Chromium "<name> Framework.framework" convention. A false
    /// positive only costs a later restore (still changeCount-guarded).
    static func isChromiumHosted(frameworks: [String]) -> Bool {
        frameworks.contains { $0.hasSuffix(" Framework.framework") }
    }
}
