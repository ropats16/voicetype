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
    /// Peak set of modifier names seen during the current capture session.
    private var peakModifierSet: Set<String> = []
    /// Key code of the most recent `.flagsChanged` event (tracks which specific
    /// modifier key was pressed, e.g. Left vs Right Option).
    private var lastModifierKeyCode: Int?

    // MARK: - Public API

    /// Begin listening for a new key binding for `target`. Cancels any
    /// in-progress capture first so the tap is resumed before the new
    /// capture's `beginHotkeyCapture` suspends it again.
    func startCapture(for target: HotkeyTarget, vm: SettingsViewModel) {
        cancelCapture(vm: vm)           // idempotent if no capture in progress
        captureTarget = target
        peakModifierSet = []
        lastModifierKeyCode = nil
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
        guard captureTarget != nil else { return event }

        switch event.type {
        case .keyDown where !event.isARepeat:
            let kc = Int(event.keyCode)
            if kc == 53 {                                   // Esc → cancel
                finishCapture(binding: nil, vm: vm)
                return nil
            }
            if !HotkeyManager.isModifierKeyCode(kc) {       // regular key → form 3
                let binding = HotkeyCapture.regularKeyBinding(
                    keyCode: kc, flags: event.modifierFlags)
                finishCapture(binding: binding, vm: vm)
                return nil
            }

        case .flagsChanged:
            let names = HotkeyCapture.modifierNames(from: event.modifierFlags)
            let kc = Int(event.keyCode)
            if !names.isEmpty {
                // On a release-of-one-while-others-remain the held set doesn't
                // grow, so lastModifierKeyCode must NOT be overwritten with the
                // released key. Only update lastModifierKeyCode when a modifier
                // key went DOWN (the held set grew).
                let newSet = Set(names)
                if newSet.count > peakModifierSet.count {
                    lastModifierKeyCode = kc     // a modifier key went DOWN (the held set grew)
                }
                peakModifierSet.formUnion(newSet)
            } else if !peakModifierSet.isEmpty {
                // All modifiers released after a non-empty peak → attempt commit.
                let peakNames = canonicalize(peakModifierSet)
                if let binding = HotkeyCapture.modifierOnlyBinding(
                    names: peakNames, lastModifierKeyCode: lastModifierKeyCode) {
                    finishCapture(binding: binding, vm: vm)
                    return nil
                }
                // modifierOnlyBinding returned nil (e.g. single modifier with no
                // tracked key code) — reset and keep waiting for another attempt.
                peakModifierSet = []
                lastModifierKeyCode = nil
            }

        default:
            break
        }
        return event
    }

    /// Re-orders a set of modifier names into canonical order
    /// (control, option, shift, command, function), matching `HotkeyCapture.modifierNames`.
    private static let modifierOrder = ["control", "option", "shift", "command", "function"]

    private func canonicalize(_ names: Set<String>) -> [String] {
        Self.modifierOrder.filter { names.contains($0) }
    }

    deinit {
        // monitor should be nil here — cancelCapture is called from
        // SettingsView.onDisappear before this object is deallocated. The guard
        // below is a last-resort safety net in case the view lifecycle diverges.
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
