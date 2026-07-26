import AppKit
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class AppCoordinator: NSObject {
    private enum DeliveryAction {
        case image
        case path

        var failureDescription: String {
            switch self {
            case .image: "Copying the image failed"
            case .path: "Copying the file path failed"
            }
        }
    }

    private static let idleSymbol = "camera.viewfinder"
    private static let successSymbol = "checkmark.circle.fill"
    /// Long enough to register, short enough that the icon is back to normal before the
    /// user looks up from the app they pasted into (PLAN D-5).
    private static let flashDuration = Duration.milliseconds(800)

    /// PLAN R-6: the unit tests run inside this app as their own host, and presenting the
    /// annotation window activates the app and takes key focus — which would yank the
    /// developer out of whatever they are doing mid-run. Presentation is the only step
    /// skipped; everything else in the capture flow, the permission gate included, runs
    /// under test exactly as it runs in production.
    private static let suppressesWindowPresentation = NSClassFromString("XCTestCase") != nil

    private let permission: any ScreenCapturePermissionProviding
    private let capture: any ScreenCapturing
    private let delivery: any SnapshotDelivering
    private let hotkey: GlobalHotkeyManager

    /// Internal, not private, so the tests can assert on what the capture flow produced.
    private(set) var activeWindowController: AnnotationWindowController?
    /// Doubles as the in-flight flag: a capture request is ignored while this is non-nil,
    /// and the tests await it to know the flow has finished.
    private(set) var captureTask: Task<Void, Never>?

    private var statusItem: NSStatusItem?
    private var messageItem: NSMenuItem?
    private var hotkeyItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var flashTask: Task<Void, Never>?

    override convenience init() {
        let permission = ScreenCapturePermission()
        self.init(
            permission: permission,
            capture: ScreenCaptureService(permission: permission),
            delivery: DeliveryService(),
            hotkey: GlobalHotkeyManager()
        )
    }

    init(
        permission: any ScreenCapturePermissionProviding,
        capture: any ScreenCapturing,
        delivery: any SnapshotDelivering,
        hotkey: GlobalHotkeyManager
    ) {
        self.permission = permission
        self.capture = capture
        self.delivery = delivery
        self.hotkey = hotkey
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()

        hotkey.onTrigger = { [weak self] in self?.requestCapture() }
        // A failed registration must not disable the app: the menu item stays a working
        // trigger and the menu says why the shortcut is not responding.
        let status = hotkey.register(.captureDefault)
        updateHotkeyItem(for: status)
        AppLogger.app.info("MacPict started")
    }

    func stop() {
        hotkey.unregister()
        flashTask?.cancel()
        flashTask = nil
        closeActiveWindow()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        messageItem = nil
        hotkeyItem = nil
        permissionItem = nil
    }

    /// The single capture entry point, shared by the global hotkey and the menu item.
    @objc func requestCapture() {
        guard captureTask == nil else {
            AppLogger.capture.info("Ignoring a capture request while one is already in flight")
            return
        }
        captureTask = Task { [weak self] in
            await self?.performCapture()
            self?.captureTask = nil
        }
    }

    /// A window left open by a previous capture stays open, live and untouched until a
    /// replacement is certain. Every early return below is a failure of the *new* capture,
    /// and none of them may destroy annotations the user has already made. Leaving that
    /// window on screen during the capture is safe: the content filter excludes this
    /// application outright, so it cannot appear in the new snapshot (PLAN D-4).
    private func performCapture() async {
        // The gate every user meets on first launch: it is what raises the TCC prompt, and
        // it runs unconditionally so the tests exercise the same path production does.
        guard permission.requestIfNeeded() else {
            refreshPermissionItem()
            report("Screen Recording permission is not granted", to: AppLogger.capture)
            return
        }

        let snapshot: CapturedSnapshot
        do {
            snapshot = try await capture.captureDisplayUnderPointer()
        } catch {
            report("Capture failed: \(String(describing: error))", to: AppLogger.capture)
            return
        }

        guard let screen = screen(for: snapshot.displayID) else {
            report("No screen is available to show the snapshot", to: AppLogger.capture)
            return
        }

        let controller = AnnotationWindowController(
            document: AnnotationDocument(image: snapshot.image),
            screen: screen
        )
        controller.annotationDelegate = self
        // The replacement exists and nothing else can fail from here, so now — and only
        // now — the previous snapshot goes.
        closeActiveWindow()
        activeWindowController = controller
        clearMessage()
        if !Self.suppressesWindowPresentation {
            controller.present()
        }
        AppLogger.capture.info(
            "Presenting a \(snapshot.image.width, privacy: .public)x\(snapshot.image.height, privacy: .public) snapshot"
        )
    }

    /// The window is placed on the display the snapshot came from, matched on display ID
    /// rather than on frame geometry (PLAN D-3).
    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { DisplayLocator.displayID(of: $0) == displayID }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func deliver(_ action: DeliveryAction, from controller: AnnotationWindowController) {
        let document = controller.document
        do {
            let png = try SnapshotExporter.png(
                image: document.image,
                annotations: document.annotations,
                // An uncropped document would otherwise pay for a crop of the whole image.
                cropRect: document.isCropped ? document.cropRect : nil
            )
            switch action {
            case .image: try delivery.copyImage(png)
            case .path: try delivery.copyFilePath(png, timestamp: Date())
            }
        } catch {
            // The window stays open. Destroying the user's annotations because a write
            // failed is the worst thing this app could do.
            report("\(action.failureDescription): \(String(describing: error))", to: AppLogger.delivery)
            return
        }
        clearMessage()
        dismiss(controller)
        flashSuccess()
    }

    private func closeActiveWindow() {
        guard let controller = activeWindowController else { return }
        dismiss(controller)
    }

    private func dismiss(_ controller: AnnotationWindowController) {
        // Cleared before closing: closing comes back through the window delegate, and this
        // is what stops that from re-entering.
        if activeWindowController === controller {
            activeWindowController = nil
        }
        controller.close()
    }

    /// The window closes instantly on delivery, so the status item is the only confirmation
    /// the user gets (PLAN D-5).
    private func flashSuccess() {
        // Cancelling the pending restore first is what keeps two deliveries in quick
        // succession from leaving the icon stuck on the checkmark.
        flashTask?.cancel()
        setStatusSymbol(Self.successSymbol)
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled else { return }
            self?.setStatusSymbol(Self.idleSymbol)
            self?.flashTask = nil
        }
    }

    private func setStatusSymbol(_ name: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "MacPict")
    }

    private func configureMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: Self.idleSymbol, accessibilityDescription: "MacPict")
        statusItem.button?.toolTip = "MacPict"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let captureItem = NSMenuItem(
            title: "Capture Display Under Pointer",
            action: #selector(requestCapture),
            keyEquivalent: "4"
        )
        captureItem.keyEquivalentModifierMask = [.control, .option, .command]
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        // Hidden until something goes wrong: an error the user cannot see is an error they
        // will blame on the app.
        let message = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        message.isEnabled = false
        message.isHidden = true
        menu.addItem(message)

        let hotkeyStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyStatus.isEnabled = false
        hotkeyStatus.isHidden = true
        menu.addItem(hotkeyStatus)

        let permissionStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        permissionStatus.isEnabled = false
        menu.addItem(permissionStatus)

        let settings = NSMenuItem(
            title: "Open Screen Recording Settings…",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacPict", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        self.statusItem = statusItem
        messageItem = message
        hotkeyItem = hotkeyStatus
        permissionItem = permissionStatus
        refreshPermissionItem()
    }

    private func updateHotkeyItem(for status: HotkeyRegistrationStatus) {
        guard case let .failed(code) = status else {
            hotkeyItem?.isHidden = true
            return
        }
        hotkeyItem?.title = "\(HotkeyShortcut.captureDefault.displayString) is unavailable (error \(code))"
        hotkeyItem?.isHidden = false
    }

    private func refreshPermissionItem() {
        // Preflight only — this never prompts, so opening the menu is always safe.
        permission.refresh()
        permissionItem?.title = "Screen Recording: \(permission.status.rawValue)"
    }

    private func report(_ message: String, to log: Logger) {
        log.error("\(message, privacy: .public)")
        messageItem?.title = message
        messageItem?.isHidden = false
    }

    private func clearMessage() {
        messageItem?.title = ""
        messageItem?.isHidden = true
    }

    @objc private func openScreenRecordingSettings() {
        permission.openSettings()
    }
}

extension AppCoordinator: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // The grant can change while the app runs, so the row is read fresh every time the
        // menu is opened rather than cached at launch.
        refreshPermissionItem()
    }
}

extension AppCoordinator: AnnotationWindowDelegate {
    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController) {
        deliver(.image, from: controller)
    }

    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController) {
        deliver(.path, from: controller)
    }

    func annotationWindowDidCancel(_ controller: AnnotationWindowController) {
        AppLogger.annotation.info("Snapshot discarded without delivery")
        dismiss(controller)
    }
}
