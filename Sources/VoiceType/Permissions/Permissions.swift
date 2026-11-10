import Foundation
import AVFoundation
import AppKit
import ApplicationServices

/// Tracks and requests the two permissions the app needs:
/// - **Microphone** (`AVCaptureDevice` / TCC) — to record audio.
/// - **Accessibility** (`AXIsProcessTrusted`) — for the global event tap,
///   the focused-field check, and synthetic ⌘V paste.
final class Permissions {
    private var hasPromptedForAccessibility = false

    var microphone: MicrophonePermission {
        MicrophonePermission(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Whether the process is trusted for Accessibility. Pass `prompt: true`
    /// to surface the system "grant access" dialog if not yet trusted.
    func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for Accessibility, one way per call. The first time this run (and
    /// only while not trusted) it shows the system prompt, which also adds
    /// the app to the Accessibility list — opening Settings alone wouldn't,
    /// leaving nothing to switch on — and has its own "Open System Settings"
    /// button. After that, or while the app reads as trusted but the tap
    /// still fails (a stale grant after a re-sign: no prompt would show), it
    /// opens System Settings.
    func requestAccessibility() {
        if !hasPromptedForAccessibility && !isAccessibilityTrusted() {
            hasPromptedForAccessibility = true
            _ = isAccessibilityTrusted(prompt: true)
        } else {
            openAccessibilitySettings()
        }
    }

    /// Request microphone access. The system prompt only appears when status is
    /// `.notDetermined`; otherwise the completion fires with the current state.
    func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch microphone {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        }
    }

    // MARK: - Deep links to System Settings

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension MicrophonePermission {
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}
