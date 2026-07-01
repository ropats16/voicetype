import Foundation
import AppKit
import ApplicationServices

/// Inspects the system's currently focused UI element for the paste gate:
/// classifies whether a ⌘V paste will land in an editable field, and nudges
/// Chromium/Electron apps into exposing their accessibility tree so that check
/// works there too. Indicator placement lives in `IndicatorController`, which
/// pins the pill to a fixed screen corner rather than chasing the caret.
struct CaretLocator {

    private func focusedElement() -> AXUIElement? {
        enableManualAccessibilityForFrontApp()
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// Chromium-based apps (all Electron apps — Claude, Codex, VS Code, Slack,
    /// Discord — plus Chrome-family browsers) build their accessibility tree
    /// lazily and expose *no* focused element to `AXUIElementCreateSystemWide()`
    /// until an assistive client asks them to. Setting `AXManualAccessibility` on
    /// the app element is the documented opt-in that turns it on, so our
    /// focused-element lookup works there too. Idempotent and cheap; safe to call
    /// on every lookup.
    private func enableManualAccessibilityForFrontApp() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Editable-field detection

    /// Standard AX roles for editable text controls.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Pure role check, factored out of `focusVerdict()` so it's unit-testable
    /// without an Accessibility round-trip.
    static func isEditableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return editableRoles.contains(role)
    }

    /// Where the currently focused element sits on the "can I paste here?"
    /// spectrum. `.unknown` means no focused element was exposed at all — common
    /// for apps we still can't introspect even after enabling manual
    /// accessibility. Callers treat `.unknown` as pasteable: silently swallowing
    /// a dictation is worse than a best-effort ⌘V into the frontmost app.
    enum FocusVerdict { case editable, notEditable, unknown }

    /// Best-effort classification of the system's currently focused UI element.
    /// Never crashes; any AX failure collapses to `.unknown`.
    func focusVerdict() -> FocusVerdict {
        guard let focused = focusedElement() else { return .unknown }
        if Self.isEditableRole(role(of: focused)) { return .editable }
        return isValueSettable(focused) ? .editable : .notEditable
    }

    private func role(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
        else { return nil }
        return roleRef as? String
    }

    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }
}
