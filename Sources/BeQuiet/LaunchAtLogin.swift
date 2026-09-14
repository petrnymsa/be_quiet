import Foundation
import ServiceManagement

/// `SMAppService.mainApp` wrapper. The service registers the *bundle*, so it
/// only works once BeQuiet runs from BeQuiet.app — never from `swift run`.
@MainActor
struct LaunchAtLogin {
    enum State: Hashable {
        case enabled
        case disabled
        /// Registered, but the user still has to allow it in System Settings.
        case requiresApproval
        /// Not running from an app bundle.
        case unavailable
    }

    var state: State {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }

        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appLogger.notice("launch at login \(isEnabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            appLogger.error(
                """
                launch at login \(isEnabled ? "register" : "unregister", privacy: .public) \
                failed: \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
