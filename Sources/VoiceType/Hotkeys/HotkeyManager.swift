import Foundation
import CoreGraphics

/// Global hotkey monitoring via a `CGEventTap` (requires Accessibility): a thin
/// adapter that decodes tap events into `KeyEvent`s, feeds them to
/// `HotkeyEdges` (where all binding rules live), and fans the resulting actions
/// out to the callbacks — hold start/stop, toggle press, cancel.
///
/// The tap runs on its own thread and run loop, so a stalled main thread (model
/// load, a slow paste) can't delay or drop key edges, nor get the tap disabled
/// by timeout. When the tap is disabled anyway, or torn down by `stop()` (a
/// rebind re-creates it), mid-hold, a synthetic hold stop is delivered so the
/// recording doesn't run to the cap.
///
/// Thread rules: `start()`, `stop()` and the callbacks are main-thread only.
/// Edge state is confined to the tap thread; actions reach main via
/// `DispatchQueue.main.async`, in order. Nothing is locked.
final class HotkeyManager {
    let hold: KeyBinding
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

    private var tap: EventTapThread?

    init(hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int) {
        self.hold = hold
        self.toggle = toggle
        self.cancelKeyCode = cancelKeyCode
    }

    /// Installs the event tap. Returns false if creation failed (almost always
    /// missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let edges = HotkeyEdges(hold: hold, toggle: toggle, cancelKeyCode: cancelKeyCode)
        // Strong capture: a synthetic release sent while stopping must still
        // arrive after the owner has dropped this manager. stop() breaks the cycle.
        guard let tap = EventTapThread(edges: edges, deliver: { actions in
            DispatchQueue.main.async { self.deliver(actions) }
        }) else {
            Log.error("Failed to create event tap (Accessibility not granted?)")
            return false
        }
        self.tap = tap
        Log.info("Hotkey event tap installed.")
        return true
    }

    /// Removes the tap. If a hold is active, its stop is still delivered.
    func stop() {
        tap?.stop()
        tap = nil
    }

    private func deliver(_ actions: [HotkeyAction]) {
        for action in actions {
            switch action {
            case .holdStart: onHoldStart?()
            case .holdStop: onHoldStop?()
            case .togglePress: onTogglePress?()
            case .cancel: onCancel?()
            }
        }
    }
}

/// Owns one `CGEventTap` and the dedicated thread whose run loop services it.
/// `init` and `stop()` are called from main; everything else runs on the tap
/// thread. The thread retains this object until its run loop exits.
private final class EventTapThread {
    private var edges: HotkeyEdges
    private let deliver: ([HotkeyAction]) -> Void
    private var port: CFMachPort?
    /// Written on the tap thread before `init` returns (ordered by the semaphore).
    private var runLoop: CFRunLoop?

    init?(edges: HotkeyEdges, deliver: @escaping ([HotkeyAction]) -> Void) {
        self.edges = edges
        self.deliver = deliver

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let current = CFRunLoopGetCurrent()
            runLoop = current
            CFRunLoopAddSource(current, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()   // until stop()
        }
        thread.name = "VoiceType.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Tears the tap down on its own thread (so edge state is never shared),
    /// releasing an active hold first, then ends the thread.
    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
                self.port = nil
            }
            send(edges.reset())
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Tap thread.
    func handle(type: CGEventType, event: CGEvent) {
        let kind: KeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // Events were dropped while the tap was off, so a release may have
            // been missed mid-hold.
            send(edges.reset())
            return
        default:
            return
        }
        send(edges.handle(KeyEvent(
            kind: kind,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)))
    }

    private func send(_ actions: [HotkeyAction]) {
        if !actions.isEmpty { deliver(actions) }
    }
}

/// C-compatible tap callback; routes to the `EventTapThread` via refcon.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTapThread>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)   // listen-only: always pass through
}
