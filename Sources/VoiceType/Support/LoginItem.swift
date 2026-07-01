import ServiceManagement

/// Our stable, testable view of the login-item state.
enum LoginItemStatus: Equatable {
    case enabled, disabled, requiresApproval, notFound, unknown
}

/// Seam over SMAppService so the enable/disable decision is unit-testable with a fake.
protocol LoginItemService {
    var rawStatus: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Real implementation backed by SMAppService.mainApp (registers the whole .app bundle as
/// the login item, correct for this menu-bar-only agent).
///
/// Note: in a non-bundled `swift run` dev context, register() will throw because
/// SMAppService requires a proper app bundle. That error surfaces to the caller rather
/// than crashing — expected behaviour.
struct MainAppLoginItemService: LoginItemService {
    var rawStatus: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Thin wrapper around a `LoginItemService` that exposes a stable Swift API
/// and contains the status-mapping logic.
final class LoginItem {

    private let service: LoginItemService

    init(service: LoginItemService = MainAppLoginItemService()) {
        self.service = service
    }

    /// Pure mapping from the raw SMAppService.Status to our LoginItemStatus.
    /// Tested exhaustively in LoginItemTests — keep this free of side effects.
    static func map(_ raw: SMAppService.Status) -> LoginItemStatus {
        switch raw {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .requiresApproval:  return .requiresApproval
        case .notFound:          return .notFound
        @unknown default:        return .unknown
        }
    }

    /// Current login-item status derived from the underlying service.
    var status: LoginItemStatus { LoginItem.map(service.rawStatus) }

    /// Convenience: `true` only when the item is fully registered and enabled.
    var isEnabled: Bool { status == .enabled }

    /// Registers or unregisters the login item.
    /// Errors from SMAppService propagate to the caller (Task 4's toggle will catch
    /// and revert the UI switch); nothing is swallowed or crashes here.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
