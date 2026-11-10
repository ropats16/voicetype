import AppKit
import ApplicationServices

/// The live focus probe over the Accessibility API. Thin on purpose: every
/// rule lives in `FocusRules`; this only gathers facts.
///
/// Every AX message carries `messagingTimeout`, so a hung frontmost app can't
/// freeze us: a message it doesn't answer fails with `kAXErrorCannotComplete`,
/// reported as `.timedOut`.
///
/// Main-thread only.
final class AXFocusProbe: FocusProbe {
    /// The AX default is ~6 s per message, and a probe sends up to four, all
    /// on main between transcription and paste. A responsive app answers in a
    /// few ms (Chromium building its tree, tens of ms), so 0.25 s never cuts
    /// off a live app, while a hung one costs at most ~0.5 s (the set-once
    /// opt-in plus the focused-element query) before we paste anyway.
    static let messagingTimeout: Float = 0.25

    private let systemWide = AXUIElementCreateSystemWide()

    /// Per process, set once: whether it's Chromium-hosted, and whether it
    /// was sent the `AXManualAccessibility` opt-in.
    private struct AppTraits {
        let isChromiumHosted: Bool
        var optedIn: Bool
    }
    private var apps: [pid_t: AppTraits] = [:]

    init() {
        // On the system-wide element this sets the global timeout.
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
    }

    func observe() -> FocusObservation {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FocusObservation(focused: focused(), bundleID: nil, isChromiumHosted: false)
        }
        let traits = optIn(app)
        return FocusObservation(focused: focused(), bundleID: app.bundleIdentifier,
                                isChromiumHosted: traits.isChromiumHosted)
    }

    // MARK: - Per app, once

    /// Looks the app up once per pid, and sends it the opt-in until it lands.
    ///
    /// Chromium apps (every Electron app — Claude, VS Code, Slack, Discord —
    /// and Chrome-family browsers) build their AX tree lazily and expose *no*
    /// focused element until an assistive client sets `AXManualAccessibility`
    /// on the app element. Native apps ignore it, so it's sent to every app;
    /// once per process is enough (it lasts for the process's lifetime). A
    /// timed-out set is retried on the next probe.
    private func optIn(_ app: NSRunningApplication) -> AppTraits {
        let pid = app.processIdentifier
        var traits = apps[pid] ?? AppTraits(isChromiumHosted: Self.isChromiumHosted(app), optedIn: false)
        if !traits.optedIn {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            traits.optedIn = result != .cannotComplete
        }
        apps[pid] = traits
        return traits
    }

    private static func isChromiumHosted(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
        return FocusRules.isChromiumHosted(frameworks: names)
    }

    // MARK: - Focused element

    private func focused() -> FocusObservation.Focused {
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if result == .cannotComplete { return .timedOut }
        guard result == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return .none }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleResult == .cannotComplete { return .timedOut }

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settableResult == .cannotComplete { return .timedOut }

        return .element(role: roleResult == .success ? roleRef as? String : nil,
                        valueSettable: settableResult == .success && settable.boolValue)
    }
}
