import Foundation
import UserNotifications

/// Thin wrapper for posting user-visible macOS notification banners.
///
/// Uses the modern `UserNotifications` framework. The catch: `UNUserNotificationCenter.current()`
/// traps in an *unbundled* process — and this project's dev loop runs via `make run` → `swift run`,
/// where there is no app bundle (`Bundle.main.bundleIdentifier` is nil). So we guard on the bundle
/// identifier: the installed `.app` posts real banners; the unbundled dev build just logs the text
/// (which the developer already sees on the console). Authorization is requested lazily on first use
/// — the system caches the decision, so repeated calls are cheap.
enum Notifier {
    static func notify(title: String, body: String) {
        // UNUserNotificationCenter.current() requires a bundled app; calling it from an
        // unbundled `swift run` process crashes. Fall back to logging there.
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("Notification (unbundled, not shown): \(title) — \(body)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Log.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No trigger → deliver immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
}
