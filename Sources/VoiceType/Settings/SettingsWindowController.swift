import AppKit
import SwiftUI

/// Manages a single, reusable settings window. The window is created lazily on
/// the first `show()` call and reused on subsequent opens — preserving any
/// position changes the user made between sessions.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// Creates the window the first time (and centres it), then brings it to
    /// front. Subsequent calls just activate and order-front without re-centering.
    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(viewModel: viewModel))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "VoiceType Settings"
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.center()
            window = w
        }
        // accessory-policy apps don't activate automatically; force-activate so
        // the settings window comes to front even if another app is focused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
