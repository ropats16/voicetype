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
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Inset from the screen's visible edges.
    private let edgeInset: CGFloat = 16

    /// This is an `.accessory` background agent, so the process (and this cached
    /// panel) survives sleep/wake. A borderless agent panel loses its all-Spaces
    /// association and can fail to re-realize after the display sleeps or the
    /// screen layout changes, stranding the pill on a single Space or making it
    /// invisible on all of them even though dictation keeps working. Watch for
    /// those events and drop the stale panel so the next `showRecording` rebuilds
    /// it from scratch with fresh window-server state.
    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshForSystemStateChange() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshForSystemStateChange() }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func showRecording() {
        model.phase = .recording
        model.level = 0
        let panel = ensurePanel()
        // Reassert behavior on every show — cheap insurance against window-server
        // state loss from events we don't explicitly observe (fullscreen /
        // Mission Control transitions can also reset collection behavior).
        applyPanelBehavior(panel)
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
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        applyPanelBehavior(panel)
        self.panel = panel
        return panel
    }

    /// Window-server state (float level + join-all-Spaces) that macOS can silently
    /// drop across sleep/wake and Space transitions. Set at creation and
    /// reasserted on every show so it can't go stale.
    private func applyPanelBehavior(_ panel: IndicatorPanel) {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    /// Sleep/wake or screen-layout change: the cached panel's window-server state
    /// may be stale. If it's on-screen (recording right now), re-pin and reassert
    /// in place; otherwise discard it so the next show rebuilds a clean one.
    private func refreshForSystemStateChange() {
        guard let panel else { return }
        if panel.isVisible {
            applyPanelBehavior(panel)
            positionBottomLeft(panel)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            self.panel = nil
        }
        Log.debug("Indicator panel refreshed after system state change.")
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
