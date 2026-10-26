import AppKit
import ServiceManagement

/// Launch-at-login, via the modern `SMAppService` API.
///
/// Preferred over writing a `LaunchAgent` plist by hand because the result is a
/// user-visible switch in System Settings ▸ General ▸ Login Items — it can be
/// seen and turned off there, rather than leaving you to hunt through
/// `~/Library` to find out why something started on its own.
enum LoginItem {
    private static let didConfigureKey = "todo.loginItemConfigured"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        switch SMAppService.mainApp.status {
        case .enabled:
            if !enabled { try SMAppService.mainApp.unregister() }

        case .notRegistered, .notFound:
            if enabled { try SMAppService.mainApp.register() }

        case .requiresApproval:
            // macOS 13+ can park a login item in a "needs your approval" state.
            // Re-registering is the documented way to ask again.
            //
            // Turning it *off* used to fall through and do nothing, so the
            // switch snapped straight back and the item stayed pending in
            // System Settings — the one state where a user most wants it gone.
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

        @unknown default:
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// Turns launch-at-login on the first run, so the app is there after a
    /// restart without anyone having to find the gear first.
    ///
    /// Only ever runs once — after that the switch in the footer is the only
    /// thing that changes it. A failure here is logged and ignored rather than
    /// blocking startup: not starting on login is a much smaller problem than
    /// an app that refuses to launch.
    static func enableOnFirstRunIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didConfigureKey) else { return }
        defaults.set(true, forKey: didConfigureKey)

        guard !isEnabled else { return }
        do {
            try setEnabled(true)
            Diag.log("launch at login enabled on first run")
        } catch {
            Diag.log("could not enable launch at login: \(error)")
        }
    }
}