import AppKit
import ApplicationServices

/// The live focus probe over the Accessibility API. Thin on purpose: the
/// focus rules live in `FocusRules`, the per-app rules in `AppTraits`; this
/// only gathers facts and sends the opt-in.
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
    /// off a live app, while a hung one costs at most ~0.5 s (the opt-in, at
    /// most every `AppTraits.timedOutRetryInterval`, plus the focused-element
    /// query) before we paste anyway.
    static let messagingTimeout: Float = 0.25

    private let systemWide = AXUIElementCreateSystemWide()
    private let workspace: NSWorkspace
    private var apps = AppTraitsCache()
    private var terminationObserver: NSObjectProtocol?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        // Process-global: on the system-wide element this sets the timeout of
        // every AX message this process sends to any element without its own
        // (`Permissions`' trust check isn't a message, so it's unaffected; any
        // future AX use inherits 0.25 s unless it sets its own).
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.apps.evict(pid: app.processIdentifier)
        }
    }

    deinit {
        if let terminationObserver { workspace.notificationCenter.removeObserver(terminationObserver) }
    }

    func observe() -> FocusObservation {
        guard let app = workspace.frontmostApplication else {
            return FocusObservation(focused: focused(), bundleID: nil, isChromiumHosted: false)
        }
        var traits = traits(of: app)
        sendOptInIfNeeded(app, &traits)
        apps.store(traits, pid: app.processIdentifier)
        return FocusObservation(focused: focused(), bundleID: app.bundleIdentifier,
                                isChromiumHosted: traits.isChromiumHosted)
    }

    // MARK: - Per app

    /// The app's cached traits, or fresh ones (bundle inspected once per process).
    private func traits(of app: NSRunningApplication) -> AppTraits {
        apps.traits(pid: app.processIdentifier, launchDate: app.launchDate)
            ?? AppTraits(launchDate: app.launchDate, isChromiumHosted: Self.isChromiumHosted(app))
    }

    /// Sets `AXManualAccessibility` on the app element when `traits` says it's due.
    ///
    /// Chromium apps (every Electron app — Claude, VS Code, Slack, Discord —
    /// and Chrome-family browsers) build their AX tree lazily and expose *no*
    /// focused element until an assistive client sets it. Native apps ignore
    /// it, so it's sent to every app; `AppTraits.recordOptIn` decides whether
    /// it's ever sent again.
    private func sendOptInIfNeeded(_ app: NSRunningApplication, _ traits: inout AppTraits) {
        let now = ProcessInfo.processInfo.systemUptime
        guard traits.needsOptIn(now: now) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        traits.recordOptIn(result, now: now)
    }

    private static func isChromiumHosted(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
        return AppTraits.isChromiumHosted(frameworks: names)
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
