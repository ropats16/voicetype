import AppKit

/// Thin wrapper for posting user-visible macOS notification banners.
///
/// Uses `NSUserNotificationCenter` rather than `UNUserNotificationCenter`: this
/// project's dev loop runs via `make run` → `swift run`, an unbundled process, and
/// `UNUserNotificationCenter` requires a proper bundle context plus an authorization
/// request that's unreliable/crashes outside one. `NSUserNotificationCenter.default`
/// works from any process with no authorization dance. It's deprecated since 10.14
/// but still functional and fine for this personal-use, non-App-Store app.
enum Notifier {
    static func notify(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
