import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MacPict

@MainActor
private final class FakeScreenCapture: ScreenCapturing {
    var image: CGImage
    var error: (any Error)?
    private(set) var callCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func captureDisplayUnderPointer() async throws -> CapturedSnapshot {
        callCount += 1
        if let error { throw error }
        let screen = NSScreen.main ?? NSScreen.screens.first
        return CapturedSnapshot(
            image: image,
            pixelSize: CGSize(width: image.width, height: image.height),
            screenFrame: screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            displayID: screen.flatMap(DisplayLocator.displayID(of:)) ?? 0
        )
    }
}

/// Counts `NSWindow.willCloseNotification` for one window. A reference type because the
/// notification block is `@Sendable`; it is only ever touched on the main queue.
private final class WindowCloseCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class FakePermission: ScreenCapturePermissionProviding {
    var status: ScreenCapturePermissionStatus
    private(set) var requestCount = 0
    private(set) var refreshCount = 0
    private(set) var openSettingsCount = 0

    init(status: ScreenCapturePermissionStatus) {
        self.status = status
    }

    func refresh() {
        refreshCount += 1
    }

    @discardableResult
    func requestIfNeeded() -> Bool {
        requestCount += 1
        return status == .granted
    }

    func openSettings() {
        openSettingsCount += 1
    }
}

@MainActor
private final class FakeDelivery: SnapshotDelivering {
    private(set) var copiedImages: [Data] = []
    private(set) var copiedPaths: [Data] = []
    var error: (any Error)?

    enum Failure: Error {
        case refused
    }

    func copyImage(_ png: Data) throws {
        if let error { throw error }
        copiedImages.append(png)
    }

    @discardableResult
    func copyFilePath(_ png: Data, timestamp: Date) throws -> URL {
        if let error { throw error }
        copiedPaths.append(png)
        return URL(fileURLWithPath: "/tmp/MacPict/MacPict-fake.png")
    }
}

@MainActor
final class CoordinatorTests: XCTestCase {
    private let imageWidth = 120
    private let imageHeight = 80

    private var capture: FakeScreenCapture!
    private var delivery: FakeDelivery!
    private var permission: FakePermission!
    private var coordinator: AppCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        capture = FakeScreenCapture(image: try makeImage(width: imageWidth, height: imageHeight))
        delivery = FakeDelivery()
        // A granting fake, so the capture flow runs the real permission gate instead of
        // bypassing it — and so nothing in this suite can reach the system's TCC prompt.
        permission = FakePermission(status: .granted)
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        coordinator?.stop()
        coordinator = nil
        permission = nil
        delivery = nil
        capture = nil
        try await super.tearDown()
    }

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(
            permission: permission,
            capture: capture,
            delivery: delivery,
            hotkey: GlobalHotkeyManager()
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// The coordinator's capture flow is asynchronous; the task is read before the first
    /// suspension, so it is always the one this request started.
    private func runCapture() async {
        coordinator.requestCapture()
        await coordinator.captureTask?.value
    }

    private func decode(_ png: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testSuccessfulCaptureDeliversExactlyOnePNGAtTheCapturedPixelSize() async throws {
        await runCapture()

        let controller = try XCTUnwrap(coordinator.activeWindowController)
        XCTAssertEqual(capture.callCount, 1)
        // The permission gate is on the path, not skipped: production reaches capture only
        // by passing it, and so does this test.
        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(controller.document.imageSize, CGSize(width: imageWidth, height: imageHeight))

        coordinator.annotationWindowDidRequestCopyImage(controller)

        XCTAssertEqual(delivery.copiedImages.count, 1)
        let decoded = try decode(try XCTUnwrap(delivery.copiedImages.first))
        XCTAssertEqual(decoded.width, imageWidth)
        XCTAssertEqual(decoded.height, imageHeight)
        XCTAssertNil(coordinator.activeWindowController)
    }

    func testCaptureThatThrowsDeliversNothingAndLeavesNoWindow() async throws {
        capture.error = ScreenCaptureError.displayNotShareable

        await runCapture()

        XCTAssertNil(coordinator.activeWindowController)
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }

    /// The branch every user meets on first launch. `requestCount` is the assertion that
    /// matters: without it this test would also pass if the flow had never run at all.
    func testDeniedPermissionStopsBeforeAnyCaptureIsAttempted() async throws {
        permission = FakePermission(status: .denied)
        coordinator = makeCoordinator()

        await runCapture()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(capture.callCount, 0)
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
        XCTAssertNil(coordinator.activeWindowController)
        // The menu's permission row is re-read on the way out, so it reports the denial
        // that just stopped the capture.
        XCTAssertEqual(permission.refreshCount, 1)
    }

    func testCopyImageActionCallsCopyImageAndNotCopyFilePath() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)

        coordinator.annotationWindowDidRequestCopyImage(controller)

        XCTAssertEqual(delivery.copiedImages.count, 1)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }

    func testCopyPathActionCallsCopyFilePathAndNotCopyImage() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)

        coordinator.annotationWindowDidRequestCopyPath(controller)

        XCTAssertEqual(delivery.copiedPaths.count, 1)
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertNil(coordinator.activeWindowController)
    }

    func testCancelDeliversNothingAndClosesTheWindow() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)

        coordinator.annotationWindowDidCancel(controller)

        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
        XCTAssertNil(coordinator.activeWindowController)
    }

    /// Losing the user's annotations because a write failed is the worst failure this app
    /// has, so a delivery error must leave the window standing.
    func testDeliveryThatThrowsLeavesTheWindowOpen() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        delivery.error = FakeDelivery.Failure.refused

        coordinator.annotationWindowDidRequestCopyImage(controller)

        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertNotNil(coordinator.activeWindowController)
        XCTAssertTrue(coordinator.activeWindowController === controller)
    }

    func testCroppedDocumentIsDeliveredAtTheCropSize() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        let cropRect = CGRect(x: 20, y: 10, width: 60, height: 40)
        controller.document.crop(to: cropRect)
        XCTAssertTrue(controller.document.isCropped)

        coordinator.annotationWindowDidRequestCopyImage(controller)

        let decoded = try decode(try XCTUnwrap(delivery.copiedImages.first))
        XCTAssertEqual(decoded.width, Int(cropRect.width))
        XCTAssertEqual(decoded.height, Int(cropRect.height))
    }

    func testASecondRequestWhileACaptureIsInFlightIsIgnored() async throws {
        coordinator.requestCapture()
        let inFlight = coordinator.captureTask
        coordinator.requestCapture()
        await inFlight?.value

        XCTAssertEqual(capture.callCount, 1)
    }

    func testANewCaptureReplacesTheWindowLeftOpenByThePreviousOne() async throws {
        await runCapture()
        let first = try XCTUnwrap(coordinator.activeWindowController)

        await runCapture()

        let second = try XCTUnwrap(coordinator.activeWindowController)
        XCTAssertFalse(first === second)
        XCTAssertEqual(capture.callCount, 2)
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }

    /// The replacement is what closes the previous window, so it must actually happen —
    /// once, and only when a new controller exists to take its place.
    func testSuccessfulReplacementClosesThePreviousWindowExactlyOnce() async throws {
        await runCapture()
        let first = try XCTUnwrap(coordinator.activeWindowController)
        let firstWindow = try XCTUnwrap(first.window)
        let closes = WindowCloseCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: firstWindow,
            queue: .main
        ) { _ in closes.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        await runCapture()

        let second = try XCTUnwrap(coordinator.activeWindowController)
        XCTAssertFalse(first === second)
        XCTAssertEqual(closes.count, 1)
        XCTAssertFalse(firstWindow.isVisible)
    }

    /// A minute of annotation must not be destroyed because a *later*, unrelated capture
    /// failed. Nothing is closed until the replacement exists.
    func testCaptureFailureLeavesAnAlreadyOpenSnapshotAndItsAnnotationsIntact() async throws {
        await runCapture()
        let first = try XCTUnwrap(coordinator.activeWindowController)
        let annotation = Annotation(kind: .box(CGRect(x: 5, y: 5, width: 30, height: 20)), style: .default)
        first.document.append(annotation)

        capture.error = ScreenCaptureError.displayNotShareable
        await runCapture()

        XCTAssertTrue(coordinator.activeWindowController === first)
        XCTAssertEqual(first.document.annotations, [annotation])
        XCTAssertEqual(capture.callCount, 2)
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }

    func testPermissionDenialOnALaterCaptureLeavesAnOpenSnapshotIntact() async throws {
        await runCapture()
        let first = try XCTUnwrap(coordinator.activeWindowController)
        let annotation = Annotation(kind: .arrow(from: .zero, to: CGPoint(x: 40, y: 30)), style: .default)
        first.document.append(annotation)

        permission.status = .denied
        await runCapture()

        XCTAssertEqual(permission.requestCount, 2)
        // The gate stopped it: the second request never reached the capture fake.
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertTrue(coordinator.activeWindowController === first)
        XCTAssertEqual(first.document.annotations, [annotation])
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }
}
