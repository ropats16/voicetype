import AppKit

/// What the menu-bar menu shows: the status header, why the app isn't ready
/// (with a fix), a model problem the reason line doesn't already cover, the
/// permission rows, the hotkeys and any config problem.
/// Pure, so it's tested without AppKit.
struct StatusMenuContent: Equatable {
    /// A line; clickable when it has an action.
    struct Row: Equatable {
        var title: String
        var action: ReadinessAction?
    }

    var header: String
    /// SF Symbol for the status item.
    var symbol: String
    /// For a status that needs the user, and for a first load (it takes a
    /// while, so it says why); another transient one is just the header.
    var reason: Row?
    /// A missing or broken model ranked behind another issue (e.g. Accessibility
    /// denied), so it isn't lost until that one is fixed.
    var modelHint: Row?
    var microphone: Row
    var accessibility: Row
    var hold: String
    var toggle: String
    var configIssues: String?

    init(status: AppStatus, inputs: ReadinessInputs, hold: String, toggle: String,
         configIssues: [ConfigIssue]) {
        header = status.headline
        if case .notReady(let issue) = status {
            symbol = "mic.slash"
            reason = Row(title: issue.detail, action: issue.action)
        } else {
            symbol = "mic"
            reason = status == .starting(.modelPreparing)
                ? Row(title: ReadinessIssue.modelPreparing.detail, action: nil) : nil
        }
        let modelIssue = AppReadiness.issues(for: inputs).first {
            switch $0 { case .modelMissing, .modelFailed: return true; default: return false }
        }
        modelHint = modelIssue.flatMap { $0 == status.issue ? nil : Row(title: $0.detail, action: $0.action) }

        switch inputs.microphone {
        case .authorized: microphone = Row(title: "Microphone: Granted", action: nil)
        case .notDetermined: microphone = Row(title: "Microphone: Not granted", action: .requestMicrophone)
        case .denied, .restricted: microphone = Row(title: "Microphone: Not granted", action: .openMicrophoneSettings)
        }
        accessibility = inputs.accessibility == .granted
            ? Row(title: "Accessibility: Granted", action: nil)
            : Row(title: "Accessibility: Not granted", action: .openAccessibilitySettings)

        self.hold = "Hold to talk: \(hold)"
        self.toggle = "Toggle to talk: \(toggle)"
        self.configIssues = configIssues.contains { $0.severity == .error }
            ? "⚠️ Config: \(configIssues.count) config issue(s) — see log"
            : nil
    }
}

/// The status item and its menu. Items are built once; `render` updates them
/// in place, so a status change never rebuilds the menu (or closes it while
/// open). Main thread only.
final class StatusMenu: NSObject, NSMenuDelegate {
    /// A clicked reason or permission row.
    var onAction: ((ReadinessAction) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    /// The menu is about to open: refresh what it shows.
    var onWillOpen: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = StatusMenu.label()
    private let reason = NSMenuItem()
    private let modelHint = NSMenuItem()
    private let microphone = NSMenuItem()
    private let accessibility = NSMenuItem()
    private let hold = StatusMenu.label()
    private let toggle = StatusMenu.label()
    private let configIssues = StatusMenu.label()
    private var symbol: String?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [reason, modelHint, microphone, accessibility] {
            row.target = self
            row.action = #selector(rowClicked(_:))
        }
        menu.items = [
            header, reason, modelHint, .separator(),
            microphone, accessibility, .separator(),
            hold, toggle,
            item("Settings…", #selector(openSettings), key: ","),
            item("Open Config File…", #selector(openConfig)),
            item("Open Models Folder…", #selector(openModelsFolder)),
            configIssues, .separator(),
            NSMenuItem(title: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        statusItem.menu = menu
    }

    func render(_ content: StatusMenuContent) {
        header.title = content.header
        set(reason, content.reason)
        set(modelHint, content.modelHint)
        set(microphone, content.microphone)
        set(accessibility, content.accessibility)
        hold.title = content.hold
        toggle.title = content.toggle
        configIssues.title = content.configIssues ?? ""
        configIssues.isHidden = content.configIssues == nil

        if content.symbol != symbol, let button = statusItem.button {
            symbol = content.symbol
            button.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: "VoiceType")
            button.image?.isTemplate = true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { onWillOpen?() }

    // MARK: - Items

    private func set(_ item: NSMenuItem, _ row: StatusMenuContent.Row?) {
        item.isHidden = row == nil
        item.title = row?.title ?? ""
        item.representedObject = row?.action
        item.isEnabled = row?.action != nil
    }

    private static func label() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func rowClicked(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? ReadinessAction { onAction?(action) }
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func openModelsFolder() { onAction?(.openModelsFolder) }
}
