import AppKit
import SwiftUI

/// Manages a single, reusable settings window. The window is created lazily on
/// the first `show()` call and reused on subsequent opens — preserving any
/// position changes the user made between sessions.
///
/// Acts as the window's `NSWindowDelegate` so `windowWillClose(_:)` fires
/// deterministically when the user clicks the red close button, regardless of
/// whether SwiftUI's `.onDisappear` fires (which is unreliable for a cached
/// `NSWindow` with `isReleasedWhenClosed=false`). This is the reliable teardown
/// path for the mid-capture window-close scenario (C1).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// Creates the window the first time (and centres it), then brings it to
    /// front. Subsequent calls just activate and order-front without re-centering.
    func show() {
        if window == nil {
            // Pass viewModel.recorder explicitly so the SwiftUI view observes its
            // @Published properties; the recorder is stable (let on the VM).
            let hosting = NSHostingView(rootView: SettingsView(viewModel: viewModel,
                                                               recorder: viewModel.recorder))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "VoiceType Settings"
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.delegate = self          // enables windowWillClose(_:) teardown
            w.center()
            window = w
        }
        // accessory-policy apps don't activate automatically; force-activate so
        // the settings window comes to front even if another app is focused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    /// Reliable teardown for mid-capture window close (C1). Called on the main
    /// thread by AppKit when the user clicks the red close button. Removes the
    /// NSEvent monitor, clears captureTarget, and resumes the global tap — even
    /// if SwiftUI's `.onDisappear` does not fire.
    func windowWillClose(_ notification: Notification) {
        viewModel.cancelCapture()
    }
}
