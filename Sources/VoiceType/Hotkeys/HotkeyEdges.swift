import CoreGraphics

/// A decoded keyboard event, as both adapters (the CGEvent tap and the Settings
/// `NSEvent` monitor) see it. `flags` uses `CGEventFlags` bits, which
/// `NSEvent.ModifierFlags` shares, including the low device-dependent bits.
struct KeyEvent: Equatable {
    enum Kind { case keyDown, keyUp, flagsChanged }

    var kind: Kind
    var keyCode: Int
    var flags: CGEventFlags
    var isAutorepeat = false
}

/// What the hold, toggle and cancel bindings mean for the dictation flow.
enum HotkeyAction: Equatable { case holdStart, holdStop, togglePress, cancel }

/// Press/release edge state for the configured bindings. Hold fires on both
/// edges, toggle on the press edge only (once per physical press, whatever the
/// autorepeat), cancel on a fresh key-down of `cancelKeyCode`.
///
/// Not thread-safe: owned by whichever thread feeds it (the tap thread).
struct HotkeyEdges {
    let hold: KeyBinding
    let toggle: KeyBinding
    let cancelKeyCode: Int

    private var holdActive = false
    private var toggleActive = false

    init(hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int) {
        self.hold = hold
        self.toggle = toggle
        self.cancelKeyCode = cancelKeyCode
    }

    mutating func handle(_ event: KeyEvent) -> [HotkeyAction] {
        var actions: [HotkeyAction] = []
        switch Self.edge(&holdActive, hold.satisfaction(by: event)) {
        case true?: actions.append(.holdStart)
        case false?: actions.append(.holdStop)
        case nil: break
        }
        if Self.edge(&toggleActive, toggle.satisfaction(by: event)) == true {
            actions.append(.togglePress)
        }
        // No edge state for cancel: the autorepeat guard prevents repeats.
        if event.kind == .keyDown, event.keyCode == cancelKeyCode, !event.isAutorepeat {
            actions.append(.cancel)
        }
        return actions
    }

    /// Call when events may have been dropped (the tap was disabled, or is
    /// being torn down). Clears all edge state; if a hold was active its
    /// release may have been lost, so a synthetic `.holdStop` is returned
    /// rather than letting the recording run to the cap.
    mutating func reset() -> [HotkeyAction] {
        defer { holdActive = false; toggleActive = false }
        return holdActive ? [.holdStop] : []
    }

    /// Folds a satisfaction reading into `active`: `true` on a press edge,
    /// `false` on a release edge, `nil` when nothing changed or the reading is
    /// irrelevant.
    private static func edge(_ active: inout Bool, _ satisfied: Bool?) -> Bool? {
        guard let satisfied, satisfied != active else { return nil }
        active = satisfied
        return satisfied
    }
}
