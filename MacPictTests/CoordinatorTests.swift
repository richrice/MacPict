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
    private(set) var uploadedImages: [Data] = []
    private(set) var uploadTargets: [String] = []
    private(set) var savedImages: [Data] = []
    private(set) var savedURLs: [URL] = []
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

    func uploadAndCopyRemotePath(_ png: Data, target: String, timestamp: Date) async throws -> String {
        if let error { throw error }
        uploadedImages.append(png)
        uploadTargets.append(target)
        return "/home/test/.cache/macpict/MacPict-fake.png"
    }

    func save(_ png: Data, to url: URL) throws {
        if let error { throw error }
        savedImages.append(png)
        savedURLs.append(url)
    }
}

/// Stands in for the save panel, which cannot be put on screen in a test run. `url` is what the
/// user "picks"; `nil` is the cancel button.
@MainActor
private final class FakeSaveLocation: SaveLocationRequesting {
    var url: URL?
    private(set) var requestCount = 0
    private(set) var suggestedNames: [String] = []
    private(set) var attachedWindows: [NSWindow?] = []

    /// When true a request parks until `release()` is called, which is how a test can hold the
    /// panel open and try to open a second one.
    var isGated = false
    /// An array, not a single continuation: a broken "one panel at a time" guard has to fail the
    /// assertion rather than strand a second request and hang the suite.
    private var gates: [CheckedContinuation<Void, Never>] = []

    func requestSaveLocation(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        requestCount += 1
        suggestedNames.append(suggestedName)
        attachedWindows.append(window)
        if isGated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gates.append(continuation)
            }
        }
        return url
    }

    func release() {
        let parked = gates
        gates.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }
}

@MainActor
final class CoordinatorTests: XCTestCase {
    private let imageWidth = 120
    private let imageHeight = 80

    /// Never `.standard`: that is the user's real preference file, and this suite writes a
    /// capture shortcut into it on every run.
    private static let defaultsSuite = "com.macpict.tests.CoordinatorTests"

    private var capture: FakeScreenCapture!
    private var delivery: FakeDelivery!
    private var saveLocation: FakeSaveLocation!
    private var saveDirectory: URL!
    private var permission: FakePermission!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var hotkeyManager: GlobalHotkeyManager!
    /// Managers that hold a shortcut so the coordinator's own registration of it must fail.
    private var blockers: [GlobalHotkeyManager] = []
    private var coordinator: AppCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        capture = FakeScreenCapture(image: try makeImage(width: imageWidth, height: imageHeight))
        delivery = FakeDelivery()
        // A path, never a real file: `FakeDelivery` records the destination instead of writing
        // to it, so nothing in this suite can put a file on the user's disk.
        saveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPictCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        saveLocation = FakeSaveLocation()
        // A granting fake, so the capture flow runs the real permission gate instead of
        // bypassing it — and so nothing in this suite can reach the system's TCC prompt.
        permission = FakePermission(status: .granted)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuite))
        defaults.removePersistentDomain(forName: Self.defaultsSuite)
        settings = SettingsStore(defaults: defaults)
        hotkeyManager = GlobalHotkeyManager()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        coordinator?.stop()
        coordinator = nil
        for blocker in blockers {
            blocker.unregister()
        }
        blockers.removeAll()
        hotkeyManager = nil
        settings = nil
        defaults?.removePersistentDomain(forName: Self.defaultsSuite)
        defaults = nil
        permission = nil
        // Any request still parked on the gate is released, so a failing test reports its
        // failure instead of leaking a continuation into the next one.
        saveLocation?.release()
        saveLocation = nil
        saveDirectory = nil
        delivery = nil
        capture = nil
        try await super.tearDown()
    }

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(
            permission: permission,
            capture: capture,
            delivery: delivery,
            saveLocation: saveLocation,
            hotkey: hotkeyManager,
            settings: settings
        )
    }

    /// Shortcuts are taken from the shipped presets rather than hand-built, so a test cannot
    /// assert against a combination the settings window would never offer.
    private func preset(_ displayString: String) throws -> HotkeyShortcut {
        try XCTUnwrap(
            HotkeyShortcut.presetGroups.flatMap(\.shortcuts).first { $0.displayString == displayString }
        )
    }

    /// Occupies `shortcut` so the coordinator's registration of it comes back `.conflict`.
    /// `RegisterEventHotKey` returns `eventHotKeyExistsErr` for a second registration of the same
    /// combination inside one process, which is the only way to make a registration fail on
    /// demand — a bogus key code registers happily.
    private func block(_ shortcut: HotkeyShortcut) {
        let blocker = GlobalHotkeyManager()
        blockers.append(blocker)
        let status = blocker.register(shortcut)
        XCTAssertTrue(
            status.isRegistered,
            "test premise: \(shortcut.displayString) has to be free for this test to occupy it, but got \(status)"
        )
    }

    /// The settings observer is delivered on `OperationQueue.main`, which may hand the block back
    /// on a later turn of the loop rather than during `post`.
    private func awaitSettingsWindowController() async throws -> SettingsWindowController {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.settingsWindowController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(coordinator.settingsWindowController)
    }

    /// What a *fresh launch* would load out of the same defaults — a second `SettingsStore`
    /// rather than a hand-decoded key, so this asserts through the production read path.
    private func shortcutAsPersisted() -> HotkeyShortcut {
        SettingsStore(defaults: defaults).hotkey
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

    func testUploadActionSendsTheExportedPNGToTheConfiguredTargetAndClosesTheWindow() async throws {
        settings.sshTarget = "devbox"
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)

        coordinator.annotationWindowDidRequestUpload(controller)
        await coordinator.uploadTask?.value

        XCTAssertEqual(delivery.uploadTargets, ["devbox"])
        let decoded = try decode(try XCTUnwrap(delivery.uploadedImages.first))
        XCTAssertEqual(decoded.width, imageWidth)
        XCTAssertEqual(decoded.height, imageHeight)
        XCTAssertNil(coordinator.activeWindowController)
    }

    func testUploadThatThrowsLeavesTheWindowOpenAndShowsTheError() async throws {
        settings.sshTarget = "devbox"
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        delivery.error = FakeDelivery.Failure.refused

        coordinator.annotationWindowDidRequestUpload(controller)
        await coordinator.uploadTask?.value

        XCTAssertTrue(delivery.uploadedImages.isEmpty)
        XCTAssertTrue(coordinator.activeWindowController === controller)
        XCTAssertEqual(
            controller.lastPresentedError,
            .init(title: "Uploading the image failed", detail: "refused")
        )
    }

    // MARK: - Save As

    /// The save flow is asynchronous because the panel is: the task is read before the first
    /// suspension, so it is always the one this request started.
    private func runSaveAs(from controller: AnnotationWindowController) async {
        coordinator.annotationWindowDidRequestSaveAs(controller)
        await coordinator.saveTask?.value
    }

    /// Waits for the gated fake to actually be inside a request. Polling, not a bare `yield()`:
    /// the save task is scheduled rather than run by `annotationWindowDidRequestSaveAs`, and
    /// releasing the gate before it has been reached would park the task forever.
    private func awaitSaveRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while saveLocation.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(saveLocation.requestCount, 1, "the save panel was never asked for a location")
    }

    func testSaveAsWritesTheExportedPNGToTheChosenURLAndClosesTheWindow() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        let destination = saveDirectory.appendingPathComponent("Chosen.png")
        saveLocation.url = destination

        await runSaveAs(from: controller)

        XCTAssertEqual(saveLocation.requestCount, 1)
        XCTAssertEqual(delivery.savedURLs, [destination])
        let decoded = try decode(try XCTUnwrap(delivery.savedImages.first))
        XCTAssertEqual(decoded.width, imageWidth)
        XCTAssertEqual(decoded.height, imageHeight)
        XCTAssertNil(coordinator.activeWindowController)
        // Save As is its own route out: neither clipboard path may fire as a side effect.
        XCTAssertEqual(delivery.copiedImages.count, 0)
        XCTAssertEqual(delivery.copiedPaths.count, 0)
    }

    /// The panel is prefilled with the same name the automatic archive route uses, and it is
    /// hung off the snapshot's own window rather than floating free of it.
    func testSaveAsSuggestsATimestampedPNGNameOnTheSnapshotsOwnWindow() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        saveLocation.url = saveDirectory.appendingPathComponent("Chosen.png")

        await runSaveAs(from: controller)

        let suggested = try XCTUnwrap(saveLocation.suggestedNames.first)
        XCTAssertTrue(suggested.hasPrefix("MacPict-"), suggested)
        XCTAssertTrue(suggested.hasSuffix(".png"), suggested)
        let attached = try XCTUnwrap(saveLocation.attachedWindows.first)
        XCTAssertTrue(attached === controller.window, "the panel has to be a sheet on the snapshot's window")
    }

    /// Cancelling the panel is not a decision about the snapshot. Nothing is written and, above
    /// all, nothing is closed — the annotations are still there to save somewhere else.
    func testCancellingTheSavePanelWritesNothingAndLeavesTheWindowOpen() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        let annotation = Annotation(kind: .box(CGRect(x: 5, y: 5, width: 30, height: 20)), style: .default)
        controller.document.append(annotation)
        saveLocation.url = nil

        await runSaveAs(from: controller)

        XCTAssertEqual(saveLocation.requestCount, 1)
        XCTAssertEqual(delivery.savedURLs, [])
        XCTAssertTrue(coordinator.activeWindowController === controller)
        XCTAssertEqual(controller.document.annotations, [annotation])
    }

    /// The same rule as every other delivery: a write that failed must leave the window standing
    /// so the user can pick somewhere else.
    func testASaveThatThrowsLeavesTheWindowOpen() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        saveLocation.url = saveDirectory.appendingPathComponent("Chosen.png")
        delivery.error = FakeDelivery.Failure.refused

        await runSaveAs(from: controller)

        XCTAssertEqual(delivery.savedURLs, [])
        XCTAssertTrue(coordinator.activeWindowController === controller)
        XCTAssertEqual(
            controller.lastPresentedError,
            .init(title: "Saving the image failed", detail: "refused")
        )
    }

    func testSaveAsWritesACroppedDocumentAtTheCropSize() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        let cropRect = CGRect(x: 20, y: 10, width: 60, height: 40)
        controller.document.crop(to: cropRect)
        saveLocation.url = saveDirectory.appendingPathComponent("Cropped.png")

        await runSaveAs(from: controller)

        let decoded = try decode(try XCTUnwrap(delivery.savedImages.first))
        XCTAssertEqual(decoded.width, Int(cropRect.width))
        XCTAssertEqual(decoded.height, Int(cropRect.height))
    }

    /// One panel per window. A second ⌘S while the first sheet is up must not stack another on
    /// top of it — the user would have two panels to dismiss and no idea which one they answered.
    func testASecondSaveRequestWhileThePanelIsUpIsIgnored() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        let destination = saveDirectory.appendingPathComponent("Chosen.png")
        saveLocation.url = destination
        saveLocation.isGated = true

        coordinator.annotationWindowDidRequestSaveAs(controller)
        let inFlight = coordinator.saveTask
        try await awaitSaveRequest()
        coordinator.annotationWindowDidRequestSaveAs(controller)

        XCTAssertEqual(saveLocation.requestCount, 1, "a second panel was opened over the first")
        saveLocation.release()
        await inFlight?.value
        XCTAssertEqual(delivery.savedURLs, [destination])
        XCTAssertNil(coordinator.saveTask, "the flag has to clear or the next save is dead")
    }

    /// The bytes are fixed when the panel opens. Whatever happens to the document behind the
    /// sheet, what lands on disk is what the user was looking at when they asked to save it.
    func testTheSavedBytesAreTheOnesFromWhenThePanelOpened() async throws {
        await runCapture()
        let controller = try XCTUnwrap(coordinator.activeWindowController)
        saveLocation.url = saveDirectory.appendingPathComponent("Chosen.png")
        saveLocation.isGated = true

        coordinator.annotationWindowDidRequestSaveAs(controller)
        let inFlight = coordinator.saveTask
        try await awaitSaveRequest()
        // Behind the sheet: a crop that would change the exported size if it were read late.
        controller.document.crop(to: CGRect(x: 20, y: 10, width: 60, height: 40))
        saveLocation.release()
        await inFlight?.value

        let decoded = try decode(try XCTUnwrap(delivery.savedImages.first))
        XCTAssertEqual(decoded.width, imageWidth)
        XCTAssertEqual(decoded.height, imageHeight)
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
        XCTAssertEqual(
            controller.lastPresentedError,
            .init(title: "Copying the image failed", detail: "refused")
        )
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

    // MARK: - Configurable capture shortcut
    //
    // These are the only tests in the suite that call `start()`. They assert on
    // `registeredShortcuts` — the coordinator's own record of what it asked for — rather than
    // on `GlobalHotkeyManager.status`, because whether Carbon accepts a given combination
    // depends on what else is running on the machine and would make the suite flaky.

    func testStartRegistersTheStoredShortcutRatherThanTheBuiltInDefault() throws {
        let chosen = try preset("F19")
        XCTAssertNotEqual(chosen, .captureDefault)
        settings.hotkey = chosen
        coordinator = makeCoordinator()

        coordinator.start()

        XCTAssertEqual(coordinator.registeredShortcuts, [chosen])
        // Stated separately so that a machine where F19 is already taken fails here, naming the
        // cause, instead of looking like a bug in the title.
        XCTAssertEqual(hotkeyManager.activeShortcut, chosen)
        XCTAssertEqual(coordinator.captureItem?.title, "Capture Display Under Pointer (F19)")
    }

    func testChangingTheStoredShortcutReRegistersWithTheNewOne() throws {
        coordinator.start()
        XCTAssertEqual(coordinator.registeredShortcuts, [.captureDefault])
        let replacement = try preset("F18")

        settings.hotkey = replacement

        XCTAssertEqual(coordinator.registeredShortcuts, [.captureDefault, replacement])
        XCTAssertEqual(hotkeyManager.activeShortcut, replacement)
        XCTAssertEqual(coordinator.captureItem?.title, "Capture Display Under Pointer (F18)")

        // Re-selecting the shortcut already in force must not tear a working registration down
        // and rebuild it, which is what `.removeDuplicates()` is there to prevent.
        settings.hotkey = replacement

        XCTAssertEqual(coordinator.registeredShortcuts, [.captureDefault, replacement])
    }

    /// A conflict is what the user gets when the combination they picked is already owned by
    /// another application. Saying nothing would leave them with a shortcut that silently does
    /// nothing, so the row has to name it.
    func testAConflictIsShownInTheMenuWithTheShortcutThatFailed() throws {
        coordinator.start()

        coordinator.updateHotkeyItem(for: .conflict("F13"))

        let row = try XCTUnwrap(coordinator.hotkeyItem)
        XCTAssertFalse(row.isHidden)
        // Both halves matter: which shortcut failed, and that the previous one carried on.
        XCTAssertEqual(row.title, "Shortcut conflict: F13 is already in use — still using ⌃⌥ C")

        coordinator.updateHotkeyItem(for: .registered("⌃⌥ C"))

        XCTAssertTrue(row.isHidden)
    }

    func testNotRegisteredIsAlsoShownRatherThanLeavingTheRowBlank() throws {
        let doomed = try preset("F15")
        block(doomed)
        settings.hotkey = doomed
        coordinator = makeCoordinator()
        coordinator.start()

        coordinator.updateHotkeyItem(for: .notRegistered)

        let row = try XCTUnwrap(coordinator.hotkeyItem)
        XCTAssertFalse(row.isHidden)
        XCTAssertEqual(row.title, "Not registered — no capture shortcut is active")
    }

    /// The menu item is the fallback that makes a failed registration survivable, so it has to
    /// keep capturing when the shortcut is dead. Driven through the item's own target/action,
    /// not by calling `requestCapture()` directly.
    func testTheCaptureMenuItemStillCapturesWhileTheHotkeyIsInAFailedState() async throws {
        coordinator.start()
        coordinator.updateHotkeyItem(for: .failed("Carbon error -50"))
        XCTAssertEqual(
            coordinator.hotkeyItem?.title,
            "Registration failed: Carbon error -50 — still using ⌃⌥ C"
        )
        XCTAssertEqual(coordinator.hotkeyItem?.isHidden, false)

        let item = try XCTUnwrap(coordinator.captureItem)
        let target = try XCTUnwrap(item.target as? NSObject)
        _ = target.perform(try XCTUnwrap(item.action))
        await coordinator.captureTask?.value

        XCTAssertEqual(capture.callCount, 1)
        XCTAssertNotNil(coordinator.activeWindowController)
    }

    func testTheMenuOffersSettingsAboveTheQuitSeparator() throws {
        coordinator.start()

        let menu = try XCTUnwrap(coordinator.captureItem?.menu)
        let settingsIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Settings…" })
        let quitIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Quit MacPict" })
        XCTAssertLessThan(settingsIndex, quitIndex)
        XCTAssertTrue(menu.items[settingsIndex + 1].isSeparatorItem)
        // No ⌘, on the status menu item: ⌘, is routed from the app menu through
        // `.macPictOpenSettings` instead, so there is only one binding for it.
        XCTAssertEqual(menu.items[settingsIndex].keyEquivalent, "")
    }

    // MARK: - Recovery from a shortcut that will not register

    /// The trap this closes: without the write-back the failed shortcut stays persisted, and the
    /// next launch — a fresh process with nothing to revert to — comes up with no hotkey at all.
    func testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive() throws {
        coordinator.start()
        XCTAssertEqual(hotkeyManager.activeShortcut, .captureDefault)
        let doomed = try preset("F18")
        block(doomed)

        settings.hotkey = doomed

        // Asked for once, and once only: the write-back must not come back round as a second
        // registration.
        XCTAssertEqual(coordinator.registeredShortcuts, [.captureDefault, doomed])
        // The selection, and what a fresh launch would read, both follow what is really live.
        XCTAssertEqual(settings.hotkey, .captureDefault)
        XCTAssertEqual(shortcutAsPersisted(), .captureDefault)
        XCTAssertEqual(hotkeyManager.activeShortcut, .captureDefault)
        // The user still learns their pick did not take, and that the old one carried on.
        XCTAssertEqual(
            coordinator.hotkeyItem?.title,
            "Shortcut conflict: F18 is already in use — still using ⌃⌥ C"
        )
        XCTAssertEqual(coordinator.hotkeyItem?.isHidden, false)
        XCTAssertEqual(coordinator.captureItem?.title, "Capture Display Under Pointer (⌃⌥ C)")
    }

    /// The window this closes: while the write-back was deferred by a turn of the main actor,
    /// there was an interval in which the store held — and had already persisted — a shortcut that
    /// does not work, and a launch after a kill inside it would have inherited that. Nothing here
    /// awaits, yields or sleeps: the assertions run on the statement after the assignment.
    func testTheRevertedShortcutIsStoredAndPersistedBeforeTheAssignmentReturns() throws {
        coordinator.start()
        XCTAssertEqual(hotkeyManager.activeShortcut, .captureDefault)
        let doomed = try preset("F14")
        block(doomed)

        settings.hotkey = doomed

        XCTAssertEqual(settings.hotkey, .captureDefault)
        // What the next launch reads, through the production decode path, with no turn of the
        // loop having elapsed since the assignment.
        XCTAssertEqual(shortcutAsPersisted(), .captureDefault)
    }

    /// The fresh-launch case: nothing is live to revert to, so the user's own choice stays put
    /// where they can see and change it, and the menu says outright that no shortcut is working.
    func testAConflictWithNothingLiveKeepsTheSelectionAndSaysNoShortcutIsActive() throws {
        let doomed = try preset("F17")
        block(doomed)
        settings.hotkey = doomed
        coordinator = makeCoordinator()

        coordinator.start()

        XCTAssertEqual(coordinator.registeredShortcuts, [doomed])
        XCTAssertNil(hotkeyManager.activeShortcut)
        XCTAssertEqual(settings.hotkey, doomed)
        XCTAssertEqual(shortcutAsPersisted(), doomed)
        XCTAssertEqual(
            coordinator.hotkeyItem?.title,
            "Shortcut conflict: F17 is already in use — no capture shortcut is active"
        )
        XCTAssertEqual(coordinator.hotkeyItem?.isHidden, false)
        // No shortcut is in force, so the item promises none.
        XCTAssertEqual(coordinator.captureItem?.title, "Capture Display Under Pointer")
    }

    /// The menu item is the escape hatch that makes the no-shortcut case survivable.
    func testTheCaptureMenuItemStillCapturesWhenNoShortcutCouldBeRegistered() async throws {
        let doomed = try preset("F16")
        block(doomed)
        settings.hotkey = doomed
        coordinator = makeCoordinator()
        coordinator.start()
        XCTAssertNil(hotkeyManager.activeShortcut)

        let item = try XCTUnwrap(coordinator.captureItem)
        let target = try XCTUnwrap(item.target as? NSObject)
        _ = target.perform(try XCTUnwrap(item.action))
        await coordinator.captureTask?.value

        XCTAssertEqual(capture.callCount, 1)
        XCTAssertNotNil(coordinator.activeWindowController)
    }

    // MARK: - ⌘, routing

    func testTheOpenSettingsNotificationOpensTheSameWindowControllerAsTheMenuItem() async throws {
        coordinator.start()
        XCTAssertNil(coordinator.settingsWindowController)

        NotificationCenter.default.post(name: .macPictOpenSettings, object: nil)

        let fromNotification = try await awaitSettingsWindowController()

        let menu = try XCTUnwrap(coordinator.captureItem?.menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
        let target = try XCTUnwrap(item.target as? NSObject)
        _ = target.perform(try XCTUnwrap(item.action))

        // Same instance: one window, reused, whichever way it is opened.
        XCTAssertTrue(coordinator.settingsWindowController === fromNotification)
    }

    func testTheOpenSettingsNotificationIsIgnoredAfterStop() async throws {
        coordinator.start()
        coordinator.stop()

        NotificationCenter.default.post(name: .macPictOpenSettings, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(coordinator.settingsWindowController)
    }
}
