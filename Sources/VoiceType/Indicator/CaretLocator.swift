import Foundation
import AppKit
import ApplicationServices

/// Finds where to place the on-screen indicator, walking the documented
/// fallback chain so feedback is *always* shown:
///
///   1. caret bounds of the focused text element (Accessibility)
///   2. the focused element's frame
///   3. the current mouse location
///   4. bottom-center of the main screen
///
/// All returned rects are in Cocoa screen coordinates (origin bottom-left).
struct CaretLocator {
    struct Target {
        enum Source: String { case caret, elementFrame, mouse, screenCenter }
        let rect: CGRect
        let source: Source
    }

    func locate() -> Target {
        if let caret = caretBounds() {
            return Target(rect: caret, source: .caret)
        }
        if let frame = focusedElementFrame() {
            return Target(rect: frame, source: .elementFrame)
        }
        let mouse = NSEvent.mouseLocation
        if mouse != .zero {
            return Target(rect: CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1), source: .mouse)
        }
        return Target(rect: bottomCenterRect(), source: .screenCenter)
    }

    // MARK: - 1. Caret bounds

    private func caretBounds() -> CGRect? {
        guard let focused = focusedElement() else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef) == .success,
              let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, !rect.isNull else { return nil }
        // A caret is zero-width; give it a nominal height if the app reports none.
        if rect.height < 1 { rect.size.height = 16 }
        return flip(rect)
    }

    // MARK: - 2. Focused element frame

    private func focusedElementFrame() -> CGRect? {
        guard let focused = focusedElement() else { return nil }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }

        return flip(CGRect(origin: position, size: size))
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else { return nil }
        return (focused as! AXUIElement)
    }

    // MARK: - Editable-field detection

    /// Standard AX roles for editable text controls.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Pure role check, factored out of `hasFocusedEditableElement()` so it's
    /// unit-testable without an Accessibility round-trip.
    static func isEditableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return editableRoles.contains(role)
    }

    /// Best-effort check for whether the system's currently focused UI element
    /// is an editable text field — used to decide whether a paste is safe, or
    /// whether to fall back to copy-only. No focused element, or any AX call
    /// failing, just means `false`; same "best effort, never crashes" style as
    /// `locate()`.
    func hasFocusedEditableElement() -> Bool {
        guard let focused = focusedElement() else { return false }
        if Self.isEditableRole(role(of: focused)) { return true }
        return isValueSettable(focused)
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

    // MARK: - 4. Screen center fallback

    private func bottomCenterRect() -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: frame.midX, y: frame.minY + 120, width: 1, height: 1)
    }

    // MARK: - Coordinate conversion

    /// Accessibility rects use a top-left origin anchored to the primary
    /// display; flip to Cocoa's bottom-left origin.
    private func flip(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
