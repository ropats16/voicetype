import Foundation
import CoreGraphics
import AppKit

/// Global hotkey monitoring via a `CGEventTap` (requires Accessibility).
///
/// Wires **hold-to-talk** (press the hold key to start recording, release to
/// transcribe) and **toggle-to-talk** (press once to start, press again to
/// stop). Both bindings are rebindable via config. Different binding forms are
/// reported differently by the system — pure-modifier combos and single
/// modifiers arrive as `flagsChanged`, regular keys as keyDown/keyUp — so the
/// per-event satisfaction rules and press/release edge detection live in the
/// pure `HotkeyMatcher`/`EdgeDetector` helpers; this class just feeds them
/// events from the tap and fans edges out to the callbacks. Esc-cancel is
/// added in Phase 2, Task 3; the structure leaves room for it.
final class HotkeyManager {
    private(set) var hold: KeyBinding
    let toggle: KeyBinding
    /// Key code (default Esc = 53) that cancels an in-progress recording.
    let cancelKeyCode: Int

    /// Fired on the main thread.
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?
    var onTogglePress: (() -> Void)?
    /// Fired on the main thread when the cancel key is pressed. Fired
    /// unconditionally — the manager doesn't track recording state, so the
    /// receiver decides whether there is anything to cancel.
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdEdge = EdgeDetector()
    private var toggleEdge = EdgeDetector()

    init(hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int) {
        self.hold = hold
        self.toggle = toggle
        self.cancelKeyCode = cancelKeyCode
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
        holdEdge = EdgeDetector()
        toggleEdge = EdgeDetector()
    }

    // MARK: - Event handling (called from the tap callback on the main run loop)

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Decode the event once, then drive each binding's edge detector off the
        // pure satisfaction rules. Pure-modifier combos type nothing; regular
        // keys still pass through (the tap is listen-only).
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags

        let holdReading = HotkeyMatcher.satisfaction(
            of: hold, eventType: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        switch holdEdge.update(with: holdReading) {
        case .press:   emit(onHoldStart)
        case .release: emit(onHoldStop)
        case nil:      break
        }

        let toggleReading = HotkeyMatcher.satisfaction(
            of: toggle, eventType: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        // Toggle fires on the press edge only, exactly once per physical press.
        if toggleEdge.update(with: toggleReading) == .press { emit(onTogglePress) }

        // Cancel key (default Esc): a plain non-modifier key, so a fresh keyDown
        // for cancelKeyCode fires onCancel directly (no edge state needed — the
        // autorepeat guard already prevents repeats while it's held). Fired
        // unconditionally; DictationController decides if there's a recording to
        // cancel. The tap is listen-only, so the Esc press still passes through
        // to the focused app — acceptable because the user is dictating (not
        // interacting with the app) while recording; switching to an
        // intercepting tap is out of scope here.
        if HotkeyMatcher.isCancelKeyDown(eventType: type, keyCode: keyCode,
                                         cancelKeyCode: cancelKeyCode, isAutorepeat: isAutorepeat) {
            emit(onCancel)
        }
    }

    /// Hops a callback to the main thread, matching the rest of the app.
    private func emit(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
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
