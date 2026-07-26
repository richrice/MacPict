import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: Error {
    case permissionDenied
    case noScreenUnderPointer
    case displayNotShareable
    case captureFailed(any Error)
}

struct CapturedSnapshot: Sendable {
    let image: CGImage
    let pixelSize: CGSize
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
}

@MainActor
protocol ScreenCapturing: AnyObject {
    func captureDisplayUnderPointer() async throws -> CapturedSnapshot
}

@MainActor
final class ScreenCaptureService: ScreenCapturing {
    private let permission: any ScreenCapturePermissionProviding

    init(permission: any ScreenCapturePermissionProviding) {
        self.permission = permission
    }

    func captureDisplayUnderPointer() async throws -> CapturedSnapshot {
        permission.refresh()
        guard permission.status == .granted else {
            AppLogger.capture.error("Capture refused: Screen Recording permission is not granted")
            throw ScreenCaptureError.permissionDenied
        }

        guard let screen = DisplayLocator.screenUnderPointer() else {
            AppLogger.capture.error("Capture refused: no screen under the pointer")
            throw ScreenCaptureError.noScreenUnderPointer
        }
        // A screen with no NSScreenNumber cannot be matched to an SCDisplay, so
        // it is indistinguishable from having found no screen at all.
        guard let displayID = DisplayLocator.displayID(of: screen) else {
            AppLogger.capture.error("Capture refused: the screen under the pointer has no display ID")
            throw ScreenCaptureError.noScreenUnderPointer
        }
        let screenFrame = screen.frame

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            AppLogger.capture.error("Failed to read shareable content: \(error.localizedDescription, privacy: .public)")
            throw ScreenCaptureError.captureFailed(error)
        }

        // C-4/D-3: AppKit frames and SCDisplay frames use opposite y directions,
        // so displays are matched on their ID and never on their geometry.
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            AppLogger.capture.error("Display \(displayID, privacy: .public) is not shareable")
            throw ScreenCaptureError.displayNotShareable
        }

        // D-4: an annotation window left open from a previous capture must not
        // appear inside the next one.
        let ownApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])

        // C-8: the filter's own scale and content bounds are authoritative for
        // the pixel size, more so than NSScreen.backingScaleFactor.
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            AppLogger.capture.error("Screenshot capture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenCaptureError.captureFailed(error)
        }

        // The system is free to adjust the requested size, so the snapshot
        // reports what actually came back.
        let pixelSize = CGSize(width: image.width, height: image.height)
        AppLogger.capture.info(
            "Captured display \(displayID, privacy: .public) at \(image.width, privacy: .public)x\(image.height, privacy: .public) pixels"
        )
        return CapturedSnapshot(image: image, pixelSize: pixelSize, screenFrame: screenFrame, displayID: displayID)
    }
}
