import AppKit

// Diagnostic path: transcribe a WAV and exit (no UI, no permissions needed).
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run(arguments: CommandLine.arguments))
}

// Menu-bar-only agent: no Dock icon, no main menu/window by default.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
