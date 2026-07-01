import AppKit
import SwiftUI

/// A borderless, non-activating panel that never steals focus from the target
/// text field.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating indicator: shows it while recording, switches it to the
/// processing spinner, and dismisses it on completion. The pill is pinned to a
/// fixed corner of the active screen. All methods must be called on the main
/// thread.
final class IndicatorController {
    private let model = IndicatorModel()
    private var panel: IndicatorPanel?

    /// Inset from the screen's visible edges.
    private let edgeInset: CGFloat = 16

    func showRecording() {
        model.phase = .recording
        model.level = 0
        let panel = ensurePanel()
        positionBottomLeft(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    func showProcessing() {
        model.phase = .processing
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() -> IndicatorPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: IndicatorView(model: model))
        hosting.layout()
        let size = hosting.fittingSize

        let panel = IndicatorPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Pin the panel to the bottom-left corner of whichever screen the mouse is
    /// on. A single fixed spot by design — we deliberately don't chase the text
    /// caret, because apps disagree about whether they report caret geometry to
    /// the accessibility API, which made the indicator jump between the caret and
    /// the mouse pointer from one app to the next.
    private func positionBottomLeft(_ panel: IndicatorPanel) {
        // Re-fit in case the content size changed (recording ↔ processing).
        if let hosting = panel.contentView {
            panel.setContentSize(hosting.fittingSize)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(CGPoint(x: visible.minX + edgeInset, y: visible.minY + edgeInset))
    }
}
