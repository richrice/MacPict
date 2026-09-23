import Foundation
import OSLog
import ServiceManagement

/// The part of `SMAppService` that `LaunchAtLogin` uses. The tests supply a fake, because the
/// test host is the real app bundle and must not register itself as a login item.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LaunchAtLogin: ObservableObject {
    private static let firstLaunchKey = "launchAtLoginSetOnFirstLaunch"

    private let service: any LoginItemService
    private let defaults: UserDefaults

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorText: String?

    /// macOS starts the app at login for both of these states. `.requiresApproval` means that
    /// the user turned MacPict off in System Settings, so the toggle shows on and the view
    /// tells the user where to approve it.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    init(service: any LoginItemService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        status = service.status
    }

    /// Turns launch at login on one time only. If the user turns it off later, the app does
    /// not turn it on again.
    func enableOnFirstLaunch() {
        guard !defaults.bool(forKey: Self.firstLaunchKey) else { return }
        defaults.set(true, forKey: Self.firstLaunchKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            AppLogger.app.error(
                "Launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        refresh()
    }

    /// The user can change the login item in System Settings while the app runs.
    func refresh() {
        status = service.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
