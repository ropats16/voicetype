import AppKit
import SwiftUI

/// Manages an `NSEvent` local monitor for live hotkey capture. Created as a
/// `@StateObject` inside `SettingsView` so its lifetime is tied to the window.
///
/// `@MainActor` isolation matches `SettingsViewModel` and the `@MainActor`-
/// annotated `NSEvent.addLocalMonitorForEvents` callback so no cross-actor
/// calls are needed. The monitor is always removed before this object is
/// deallocated: `SettingsView.onDisappear` calls `cancelCapture` on every
/// window-close path, leaving `monitor` nil by the time `deinit` runs.
@MainActor
final class HotkeyRecorder: ObservableObject {

    /// Which binding is currently being recorded; drives per-row "Recording…" UI.
    /// `nil` when no capture is in progress.
    @Published private(set) var captureTarget: HotkeyTarget?

    // MARK: - Private capture state

    /// Monitor token from `NSEvent.addLocalMonitorForEvents`. Marked
    /// `nonisolated(unsafe)` so `deinit` (non-isolated in Swift 6) can access
    /// it as a last-resort safety net; in practice it is nil by then.
    nonisolated(unsafe) private var monitor: Any?
    /// The capture session; all capture-to-binding rules live in `KeyBinding.Capture`.
    private var session = KeyBinding.Capture()

    // MARK: - Public API

    /// Begin listening for a new key binding for `target`. Cancels any
    /// in-progress capture first so the tap is resumed before the new
    /// capture's `beginHotkeyCapture` suspends it again.
    func startCapture(for target: HotkeyTarget, vm: SettingsViewModel) {
        cancelCapture(vm: vm)           // idempotent if no capture in progress
        captureTarget = target
        session = KeyBinding.Capture()
        vm.beginHotkeyCapture()         // suspend global tap + set isCapturing

        // The handler is @MainActor — same isolation as this class.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event, vm: vm)
        }
    }

    /// Remove the monitor and commit (or cancel when `binding` is nil). Safe to
    /// call when no capture is in progress (`captureTarget == nil`).
    func finishCapture(binding: KeyBinding?, vm: SettingsViewModel) {
        removeMonitor()
        guard let target = captureTarget else { return }
        captureTarget = nil
        vm.commitHotkey(binding, for: target)
    }

    /// Cancel any in-progress capture without committing a new binding (e.g.
    /// called from `SettingsView.onDisappear` when the window closes).
    func cancelCapture(vm: SettingsViewModel) {
        finishCapture(binding: nil, vm: vm)
    }

    // MARK: - Private

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Processes one `NSEvent` during capture. Returns `nil` to consume the
    /// event (prevents it reaching the window's responder chain); returns the
    /// event unchanged to pass it through.
    private func handle(event: NSEvent, vm: SettingsViewModel) -> NSEvent? {
        guard captureTarget != nil, let keyEvent = KeyEvent(event) else { return event }
        switch session.handle(keyEvent) {
        case .pending:
            return event
        case .cancelled:
            finishCapture(binding: nil, vm: vm)
            return nil
        case .captured(let binding):
            finishCapture(binding: binding, vm: vm)
            return nil
        }
    }

    deinit {
        // monitor should be nil here — cancelCapture is called from
        // SettingsView.onDisappear before this object is deallocated. The guard
        // below is a last-resort safety net in case the view lifecycle diverges.
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

private extension KeyEvent {
    /// Decodes the event types the capture monitor listens for. `isARepeat` is
    /// only read for key events: AppKit raises on it for `.flagsChanged`.
    init?(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        switch event.type {
        case .keyDown:
            self.init(kind: .keyDown, keyCode: Int(event.keyCode), flags: flags, isAutorepeat: event.isARepeat)
        case .flagsChanged:
            self.init(kind: .flagsChanged, keyCode: Int(event.keyCode), flags: flags)
        default:
            return nil
        }
    }
}
