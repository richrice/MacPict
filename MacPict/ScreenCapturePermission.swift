import AppKit
import CoreGraphics

enum ScreenCapturePermissionStatus: String, Sendable {
    case granted = "Granted"
    case denied = "Not granted"
}

@MainActor
protocol ScreenCapturePermissionProviding: AnyObject {
    var status: ScreenCapturePermissionStatus { get }
    func refresh()
    @discardableResult func requestIfNeeded() -> Bool
    func openSettings()
}

@MainActor
final class ScreenCapturePermission: ObservableObject, ScreenCapturePermissionProviding {
    private static let settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    @Published private(set) var status: ScreenCapturePermissionStatus = .denied

    init() {
        refresh()
    }

    func refresh() {
        // C-9/C-10: the preflight call is the only permission signal used; no
        // SCStreamError code is treated as a permission answer.
        status = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    @discardableResult
    func requestIfNeeded() -> Bool {
        refresh()
        guard status != .granted else { return true }
        // macOS shows the TCC dialog out of band and does not honour a fresh
        // grant until the app is relaunched, so this usually returns false the
        // first time it is called.
        let granted = CGRequestScreenCaptureAccess()
        status = granted ? .granted : .denied
        if !granted {
            AppLogger.capture.error("Screen Recording permission was requested and is still not granted")
        }
        return granted
    }

    func openSettings() {
        guard let url = URL(string: Self.settingsURLString) else {
            AppLogger.capture.error("Screen Recording settings URL is malformed")
            return
        }
        if !NSWorkspace.shared.open(url) {
            AppLogger.capture.error("Failed to open the Screen Recording settings pane")
        }
    }
}
