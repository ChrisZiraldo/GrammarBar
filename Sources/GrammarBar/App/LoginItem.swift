import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService` (macOS 13+) for launch-at-login.
enum LoginItem {

    /// Call at app launch to synchronise the stored preference with SMAppService.
    static func syncOnLaunch() {
        guard #available(macOS 13, *) else { return }
        let wantEnabled = SettingsStore.shared.launchAtLogin
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            if !wantEnabled { try? service.unregister() }
        case .notRegistered, .requiresApproval:
            if wantEnabled { try? service.register() }
        default:
            break
        }
    }

    /// Enable or disable launch-at-login, also persisting the preference.
    static func setEnabled(_ enabled: Bool) {
        SettingsStore.shared.launchAtLogin = enabled
        guard #available(macOS 13, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // The user may need to grant approval in System Settings —
            // opening the pane is handled by the UI on registration failure.
        }
    }

    /// Whether launch-at-login is currently registered with SMAppService.
    static var isRegistered: Bool {
        guard #available(macOS 13, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
