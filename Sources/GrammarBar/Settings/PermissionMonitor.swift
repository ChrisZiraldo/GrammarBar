import AppKit
import ApplicationServices
import Combine

/// Watches the two privacy permissions GrammarBar needs and publishes changes as
/// they happen, so screens update the moment the user flips a switch in System
/// Settings instead of needing a manual re-check.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted = CGPreflightListenEventAccess()

    private var timer: Timer?

    var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    /// Starts polling once a second. Safe to call repeatedly.
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let accessibility = AXIsProcessTrusted()
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }

        let input = CGPreflightListenEventAccess()
        if input != inputMonitoringGranted { inputMonitoringGranted = input }
    }

    // MARK: - Opening System Settings

    func openAccessibilitySettings() {
        open("com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
