import Foundation
import CoreGraphics
import AppKit

/// Global hotkey monitoring via a `CGEventTap` (requires Accessibility).
///
/// Phase 1 wires **hold-to-talk**: press the hold key to start recording,
/// release to transcribe. The default key is a modifier (Right Option), which
/// the system reports via `flagsChanged` rather than keyDown/keyUp — so we
/// detect press/release using the device-specific modifier bit. Toggle and
/// Esc-cancel are added in Phase 2; the structure leaves room for them.
final class HotkeyManager {
    private(set) var hold: KeyBinding

    /// Fired on the main thread.
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdActive = false

    init(hold: KeyBinding) {
        self.hold = hold
    }

    /// Installs the event tap. Returns false if creation failed (almost always
    /// missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: refcon
        ) else {
            Log.error("Failed to create event tap (Accessibility not granted?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        Log.info("Hotkey event tap installed.")
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        holdActive = false
    }

    // MARK: - Event handling (called from the tap callback on the main run loop)

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Modifier-combo hold (e.g. fn+Shift): no main key, so keyCode < 0. We
        // evaluate the whole modifier set on every flagsChanged. Because these
        // are pure modifiers, nothing is ever typed into the focused field.
        if hold.keyCode < 0, !hold.modifiers.isEmpty {
            guard type == .flagsChanged else { return }
            let required = Self.flags(for: hold.modifiers)
            setHold(!required.isEmpty && event.flags.isSuperset(of: required))
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if Self.isModifierKeyCode(hold.keyCode) {
            guard type == .flagsChanged, keyCode == hold.keyCode else { return }
            let pressed = (event.flags.rawValue & Self.deviceBit(for: hold.keyCode)) != 0
            setHold(pressed)
        } else {
            if type == .keyDown, keyCode == hold.keyCode { setHold(true) }
            else if type == .keyUp, keyCode == hold.keyCode { setHold(false) }
        }
    }

    private func setHold(_ active: Bool) {
        guard active != holdActive else { return }
        holdActive = active
        DispatchQueue.main.async { [weak self] in
            active ? self?.onHoldStart?() : self?.onHoldStop?()
        }
    }

    // MARK: - Modifier key helpers

    /// Combined `CGEventFlags` for a set of modifier names (used by combo holds).
    static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "function", "fn", "globe": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    /// Modifier virtual key codes that are reported via flagsChanged.
    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        // 54 RCmd, 55 LCmd, 56 LShift, 58 LOpt, 59 LCtrl, 60 RShift, 61 ROpt, 62 RCtrl
        [54, 55, 56, 58, 59, 60, 61, 62].contains(keyCode)
    }

    /// Device-specific modifier bit (NX_DEVICE…KEYMASK) for a modifier key code,
    /// used to tell press from release on flagsChanged.
    static func deviceBit(for keyCode: Int) -> UInt64 {
        switch keyCode {
        case 55: return 0x08        // Left Command
        case 54: return 0x10        // Right Command
        case 56: return 0x02        // Left Shift
        case 60: return 0x04        // Right Shift
        case 58: return 0x20        // Left Option
        case 61: return 0x40        // Right Option
        case 59: return 0x01        // Left Control
        case 62: return 0x2000      // Right Control
        default: return 0
        }
    }
}

/// C-compatible tap callback; routes back to the `HotkeyManager` via refcon.
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        manager.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)   // listen-only: always pass through
}
