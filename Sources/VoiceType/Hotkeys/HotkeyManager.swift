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
/// `DispatchQueue.main.async`, in order. Nothing is locked. Releasing the
/// manager stops its tap.
final class HotkeyManager {
    /// Fired on the main thread.
    var onHoldStart: (() -> Void)? {
        get { delivery.onHoldStart } set { delivery.onHoldStart = newValue }
    }
    var onHoldStop: (() -> Void)? {
        get { delivery.onHoldStop } set { delivery.onHoldStop = newValue }
    }
    var onTogglePress: (() -> Void)? {
        get { delivery.onTogglePress } set { delivery.onTogglePress = newValue }
    }
    /// Fired on the main thread when the cancel key is pressed. Fired
    /// unconditionally — the manager doesn't track recording state, so the
    /// receiver decides whether there is anything to cancel.
    var onCancel: (() -> Void)? {
        get { delivery.onCancel } set { delivery.onCancel = newValue }
    }

    /// Fresh edge state, copied into each tap.
    private let edges: HotkeyEdges
    private let delivery = HotkeyDelivery()
    private var tap: EventTapThread?

    init(hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int) {
        edges = HotkeyEdges(hold: hold, toggle: toggle, cancelKeyCode: cancelKeyCode)
    }

    deinit { stop() }

    /// Installs the event tap. Returns false if creation failed (almost always
    /// missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // Captures the delivery, not self: no cycle through the tap, and a
        // synthetic release sent while stopping still lands after the owner
        // has dropped this manager.
        let delivery = delivery, generation = delivery.generation
        guard let tap = EventTapThread(edges: edges, deliver: { actions in
            DispatchQueue.main.async { delivery.deliver(actions, generation: generation) }
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
        guard let tap else { return }
        delivery.invalidate()
        tap.stop()
        self.tap = nil
    }
}

/// The main-thread end of the tap → main hop. Main-thread only.
///
/// `stop()` is asynchronous — the tap is torn down on its own thread — so a
/// stopped tap can still flush events it read just before. Delivering those
/// presses next to the replacement tap's would double-fire (a toggle press
/// that starts then immediately stops a recording), so actions from an older
/// generation are dropped. Releases always pass: a hold stop is harmless when
/// idle, and may be the synthetic release from teardown.
final class HotkeyDelivery {
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?
    var onTogglePress: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The tap generation whose actions are live.
    private(set) var generation = 0

    /// Retires the current tap's actions (all but releases).
    func invalidate() { generation += 1 }

    func deliver(_ actions: [HotkeyAction], generation: Int) {
        let isLive = generation == self.generation
        for action in actions where isLive || action == .holdStop {
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
        self.runLoop = nil   // a second stop is a no-op
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
