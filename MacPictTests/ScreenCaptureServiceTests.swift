import XCTest
@testable import MacPict

@MainActor
private final class StubScreenCapturePermission: ScreenCapturePermissionProviding {
    private(set) var refreshCount = 0
    private(set) var statusReadCount = 0
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    private let reportedStatus: ScreenCapturePermissionStatus

    init(status: ScreenCapturePermissionStatus) {
        reportedStatus = status
    }

    var status: ScreenCapturePermissionStatus {
        statusReadCount += 1
        return reportedStatus
    }

    func refresh() {
        refreshCount += 1
    }

    @discardableResult
    func requestIfNeeded() -> Bool {
        requestCount += 1
        return reportedStatus == .granted
    }

    func openSettings() {
        openSettingsCount += 1
    }
}

final class ScreenCaptureServiceTests: XCTestCase {
    @MainActor
    func testCaptureThrowsPermissionDeniedWithoutReachingScreenCaptureKit() async {
        let permission = StubScreenCapturePermission(status: .denied)
        let service = ScreenCaptureService(permission: permission)

        do {
            _ = try await service.captureDisplayUnderPointer()
            XCTFail("Capture must not produce a snapshot while Screen Recording permission is denied")
        } catch let error as ScreenCaptureError {
            // .permissionDenied is thrown by the pre-flight gate and by nothing
            // else: a display that cannot be resolved yields .noScreenUnderPointer,
            // an unshareable display yields .displayNotShareable, and every failure
            // at or beyond SCShareableContent is wrapped as .captureFailed. So this
            // case can only be reached before any ScreenCaptureKit call is made.
            guard case .permissionDenied = error else {
                return XCTFail("Expected .permissionDenied, got \(error)")
            }
        } catch {
            return XCTFail("Expected a ScreenCaptureError, got \(error)")
        }

        // The gate consults the injected provider rather than the process's real
        // TCC state: had it not, this machine's actual permission would decide the
        // outcome and the assertion above could not hold.
        XCTAssertEqual(permission.refreshCount, 1)
        XCTAssertGreaterThan(permission.statusReadCount, 0)
        // Capture must never raise a TCC prompt of its own; requesting is the
        // coordinator's job, driven by the user.
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(permission.openSettingsCount, 0)
    }

    @MainActor
    func testConcreteScreenCapturePermissionSatisfiesTheProvidingProtocol() {
        // Guards the seam itself: if ScreenCapturePermission ever stops conforming,
        // AppCoordinator's real wiring breaks and this fails at compile time.
        let permission: any ScreenCapturePermissionProviding = ScreenCapturePermission()
        XCTAssertTrue(permission is ScreenCapturePermission)
        _ = ScreenCaptureService(permission: permission)
    }
}
