import AppKit
import SwiftUI

/// A borderless, non-activating panel that never steals focus from the target
/// text field.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating indicator: shows it near the caret while recording,
/// switches it to the processing spinner, and dismisses it on completion.
/// All methods must be called on the main thread.
final class IndicatorController {
    private let model = IndicatorModel()
    private let locator = CaretLocator()
    private var panel: IndicatorPanel?

    /// Gap between the caret/element and the indicator.
    private let gap: CGFloat = 6

    func showRecording() {
        model.phase = .recording
        model.level = 0
        let panel = ensurePanel()
        position(panel, near: locator.locate())
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

    /// Place the panel just below the target, clamped to the visible screen.
    private func position(_ panel: IndicatorPanel, near target: CaretLocator.Target) {
        // Re-fit in case content size changed.
        if let hosting = panel.contentView {
            let size = hosting.fittingSize
            panel.setContentSize(size)
        }
        let panelSize = panel.frame.size
        let r = target.rect

        var origin: CGPoint
        switch target.source {
        case .caret, .elementFrame:
            // Below the caret/element, left-aligned.
            origin = CGPoint(x: r.minX, y: r.minY - panelSize.height - gap)
        case .mouse:
            // Just above-right of the cursor.
            origin = CGPoint(x: r.minX + 12, y: r.minY + 12)
        case .screenCenter:
            origin = CGPoint(x: r.midX - panelSize.width / 2, y: r.minY)
        }

        // Clamp to the screen that contains the target point.
        let screen = NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: r.midX, y: r.midY))
        } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - panelSize.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - panelSize.height - 4)
        }
        panel.setFrameOrigin(origin)
    }
}
