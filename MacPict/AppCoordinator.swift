import AppKit
import Combine
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

    private static let saveFailureDescription = "Saving the image failed"
    private static let uploadFailureDescription = "Uploading the image failed"

    private static let idleSymbol = "camera.viewfinder"
    private static let successSymbol = "checkmark.circle.fill"
    private static let captureTitle = "Capture Display Under Pointer"
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
    private let saveLocation: any SaveLocationRequesting
    private let hotkey: GlobalHotkeyManager
    private let settings: SettingsStore

    /// Internal, not private, so the tests can assert on what the capture flow produced.
    private(set) var activeWindowController: AnnotationWindowController?
    /// Doubles as the in-flight flag: a capture request is ignored while this is non-nil,
    /// and the tests await it to know the flow has finished.
    private(set) var captureTask: Task<Void, Never>?
    /// Doubles as the panel-is-up flag: a save request is ignored while this is non-nil, so the
    /// user cannot stack sheets on one window, and the tests await it to know the save finished.
    private(set) var saveTask: Task<Void, Never>?
    /// Doubles as the in-flight flag so repeated shortcut presses cannot start concurrent uploads
    /// of the same snapshot.
    private(set) var uploadTask: Task<Void, Never>?
    /// Every shortcut handed to `GlobalHotkeyManager`, in order. Internal so the tests can
    /// assert on the coordinator's decision — which shortcut, and how many times — rather
    /// than on Carbon's registration result, which any other running application can change
    /// from one run to the next.
    private(set) var registeredShortcuts: [HotkeyShortcut] = []

    /// Internal, not private, so the tests can assert on the two rows whose text is the only
    /// thing that tells the user a shortcut is not working.
    private(set) var captureItem: NSMenuItem?
    private(set) var hotkeyItem: NSMenuItem?

    /// Built on first request and reused, never rebuilt. Internal so the tests can prove that
    /// the menu item and ⌘, reach the same instance.
    private(set) var settingsWindowController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var messageItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var flashTask: Task<Void, Never>?
    private var hotkeyCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private var settingsObserver: (any NSObjectProtocol)?
    /// Set only while `apply(_:)` is writing a reverted shortcut back into the store. See
    /// `revertStoredShortcut(to:)`.
    private var isRevertingStoredShortcut = false

    override convenience init() {
        let permission = ScreenCapturePermission()
        self.init(
            permission: permission,
            capture: ScreenCaptureService(permission: permission),
            delivery: DeliveryService(),
            saveLocation: SaveLocationPanel(),
            hotkey: GlobalHotkeyManager(),
            settings: SettingsStore()
        )
    }

    init(
        permission: any ScreenCapturePermissionProviding,
        capture: any ScreenCapturing,
        delivery: any SnapshotDelivering,
        saveLocation: any SaveLocationRequesting,
        hotkey: GlobalHotkeyManager,
        settings: SettingsStore
    ) {
        self.permission = permission
        self.capture = capture
        self.delivery = delivery
        self.saveLocation = saveLocation
        self.hotkey = hotkey
        self.settings = settings
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()

        hotkey.onTrigger = { [weak self] in self?.requestCapture() }
        // The user's stored choice, not the built-in default: the whole point of the setting
        // is that ⌃⌥⌘4 was not reachable one-handed.
        //
        // A failed registration must not disable the app: the menu item stays a working
        // trigger and the menu says why the shortcut is not responding.
        apply(settings.hotkey)

        // `hotkeyDidChange`, not `$hotkey`: it fires from `didSet`, once the store has settled and
        // persisted, which is what lets `revertStoredShortcut` write a correction that sticks.
        //
        // No `dropFirst()`. A `PassthroughSubject` does not replay to a new subscriber, so there
        // is no initial value to skip and the operator would eat the user's first real change.
        // `removeDuplicates()` stays: re-selecting the shortcut already in force must not tear
        // down a working registration and re-make it.
        hotkeyCancellable = settings.hotkeyDidChange
            .removeDuplicates()
            .sink { [weak self] shortcut in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The one value that must not be acted on: the coordinator's own write-back
                    // of a shortcut the manager already reverted to. See `revertStoredShortcut`.
                    guard !self.isRevertingStoredShortcut else { return }
                    self.apply(shortcut)
                }
            }
        // The status is no longer written once at launch — every shortcut change rewrites it —
        // so the menu row follows the publisher instead of a single return value. The sink
        // fires immediately with the current status, which is what registration just produced.
        statusCancellable = hotkey.$status
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.updateHotkeyItem(for: status) }
            }
        // ⌘, and the app menu's Settings item, routed here by `MacPictApp` so they open the real
        // window instead of the placeholder SwiftUI `Settings` scene.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macPictOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettingsWindow() }
        }
        AppLogger.app.info("MacPict started")
    }

    func stop() {
        // Cancelled before teardown so no late change can write into a dismantled menu.
        hotkeyCancellable = nil
        statusCancellable = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
        hotkey.unregister()
        registeredShortcuts.removeAll()
        flashTask?.cancel()
        flashTask = nil
        closeActiveWindow()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        messageItem = nil
        captureItem = nil
        hotkeyItem = nil
        permissionItem = nil
    }

    /// The single place a shortcut reaches the hotkey manager, so the menu, the record of what
    /// was asked for and the stored selection cannot drift from what was registered.
    ///
    /// When a chosen shortcut fails, `GlobalHotkeyManager` reverts to the last one that did
    /// register, and the stored selection has to follow it. Otherwise the dead shortcut stays
    /// persisted, and the *next* launch — a fresh process, with no last-good shortcut to fall
    /// back on — comes up with no working hotkey at all. `status` still reports the failure of
    /// the shortcut the user picked, so they learn their choice did not take.
    private func apply(_ shortcut: HotkeyShortcut) {
        registeredShortcuts.append(shortcut)
        let status = hotkey.register(shortcut)
        // Read after `register` has returned rather than trusting the `$status` sink: inside
        // that sink the manager has not necessarily settled `activeShortcut` yet.
        let live = hotkey.activeShortcut
        updateHotkeyItem(for: status)
        updateCaptureItem(for: live)

        guard !status.isRegistered, let live, live != shortcut else { return }
        revertStoredShortcut(to: live)
    }

    /// Synchronous, and it has to be: the assignment below runs while the store's outer `didSet`
    /// is still on the stack, so the corrected shortcut is stored and persisted by its own nested
    /// `didSet` before that outer call returns. There is no turn of the loop during which the
    /// store holds — or has persisted — a shortcut that does not work, which is exactly what a
    /// later launch would otherwise inherit.
    ///
    /// **The write re-enters.** That nested `didSet` sends on `hotkeyDidChange` in turn, and
    /// `removeDuplicates()` cannot absorb it — the reverted shortcut genuinely differs from the
    /// one that just failed — so the sink would register it all over again.
    /// `isRevertingStoredShortcut` is what stops that. It is set here and nowhere else, and it
    /// brackets exactly the one assignment whose nested delivery it has to suppress; the subject
    /// delivers that nested send synchronously, so the flag is true for precisely that callback.
    private func revertStoredShortcut(to shortcut: HotkeyShortcut) {
        isRevertingStoredShortcut = true
        defer { isRevertingStoredShortcut = false }
        settings.hotkey = shortcut
        AppLogger.hotkey.info(
            "Stored selection reverted to \(shortcut.displayString, privacy: .public), the shortcut still registered"
        )
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
        do {
            let png = try exportedPNG(of: controller.document)
            switch action {
            case .image: try delivery.copyImage(png)
            case .path: try delivery.copyFilePath(png, timestamp: Date())
            }
        } catch {
            // The window stays open. Destroying the user's annotations because a write
            // failed is the worst thing this app could do.
            reportDeliveryFailure(action.failureDescription, error: error, on: controller)
            return
        }
        clearMessage()
        dismiss(controller)
        flashSuccess()
    }

    private func exportedPNG(of document: AnnotationDocument) throws -> Data {
        try SnapshotExporter.png(
            image: document.image,
            annotations: document.annotations,
            // An uncropped document would otherwise pay for a crop of the whole image.
            cropRect: document.isCropped ? document.cropRect : nil
        )
    }

    /// Save As, in two steps that must stay in this order: the PNG is produced *before* the
    /// panel goes up, so an export that cannot succeed says so immediately instead of asking
    /// the user to name a file for bytes that do not exist.
    ///
    /// The bytes are then fixed for the life of the panel. That is the point: the window is
    /// live behind a sheet only in the sense that it still exists, and what lands on disk is
    /// what the user was looking at when they asked to save it.
    private func saveAs(from controller: AnnotationWindowController) {
        guard saveTask == nil else {
            AppLogger.delivery.info("Ignoring a save request while the save panel is already up")
            return
        }
        let png: Data
        do {
            png = try exportedPNG(of: controller.document)
        } catch {
            reportDeliveryFailure(Self.saveFailureDescription, error: error, on: controller)
            return
        }
        saveTask = Task { [weak self] in
            await self?.performSave(png, from: controller)
            self?.saveTask = nil
        }
    }

    private func performSave(_ png: Data, from controller: AnnotationWindowController) async {
        let suggestedName = DeliveryService.fileName(for: Date())
        guard let url = await saveLocation.requestSaveLocation(
            suggestedName: suggestedName,
            attachedTo: controller.window
        ) else {
            // Cancelling the panel is not a failure and not a decision about the snapshot: the
            // window stays exactly as it was, annotations and all.
            AppLogger.delivery.info("Save cancelled; the snapshot is still open")
            return
        }
        do {
            try delivery.save(png, to: url)
        } catch {
            reportDeliveryFailure(Self.saveFailureDescription, error: error, on: controller)
            return
        }
        clearMessage()
        dismiss(controller)
        flashSuccess()
    }

    private func upload(from controller: AnnotationWindowController) {
        guard uploadTask == nil else {
            AppLogger.delivery.info("Ignoring an upload request while one is already in flight")
            return
        }
        let png: Data
        do {
            png = try exportedPNG(of: controller.document)
        } catch {
            reportDeliveryFailure(Self.uploadFailureDescription, error: error, on: controller)
            return
        }
        let target = settings.sshTarget
        uploadTask = Task { [weak self] in
            await self?.performUpload(png, target: target, from: controller)
            self?.uploadTask = nil
        }
    }

    private func performUpload(
        _ png: Data,
        target: String,
        from controller: AnnotationWindowController
    ) async {
        do {
            try await delivery.uploadAndCopyRemotePath(
                png,
                target: target,
                timestamp: Date()
            )
        } catch {
            reportDeliveryFailure(Self.uploadFailureDescription, error: error, on: controller)
            return
        }
        clearMessage()
        dismiss(controller)
        flashSuccess()
    }

    private func reportDeliveryFailure(
        _ title: String,
        error: any Error,
        on controller: AnnotationWindowController
    ) {
        let detail = (error as? any LocalizedError)?.errorDescription
            ?? String(describing: error)
        report("\(title): \(detail)", to: AppLogger.delivery)
        controller.presentError(title: title, detail: detail)
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

        // No key equivalent: the shortcut is a Carbon global hotkey, and any key equivalent set
        // here would be AppKit's own, handled separately and only while the menu is in the
        // responder chain. Several of the offered shortcuts (the bare function keys) have no
        // honest key-equivalent spelling at all. So the shortcut is written into the title,
        // where it describes the hotkey that is actually in force rather than imitating it.
        let captureRow = NSMenuItem(title: Self.captureTitle, action: #selector(requestCapture), keyEquivalent: "")
        captureRow.target = self
        menu.addItem(captureRow)
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

        let screenRecording = NSMenuItem(
            title: "Open Screen Recording Settings…",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        )
        screenRecording.target = self
        menu.addItem(screenRecording)

        let appSettings = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: "")
        appSettings.target = self
        menu.addItem(appSettings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacPict", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        self.statusItem = statusItem
        messageItem = message
        captureItem = captureRow
        hotkeyItem = hotkeyStatus
        permissionItem = permissionStatus
        updateCaptureItem(for: hotkey.activeShortcut)
        refreshPermissionItem()
    }

    /// The title names the shortcut that is actually registered, not the one that was chosen —
    /// promising a combination that no longer works would contradict the status row directly
    /// below it. When nothing is registered the title names no shortcut at all.
    private func updateCaptureItem(for shortcut: HotkeyShortcut?) {
        guard let shortcut else {
            captureItem?.title = Self.captureTitle
            return
        }
        captureItem?.title = "\(Self.captureTitle) (\(shortcut.displayString))"
    }

    /// Internal, not private, so the tests can drive a status the app cannot be made to produce
    /// on demand: a conflict depends on what other applications on the machine already own.
    ///
    /// Every non-registered case is shown, `.conflict` above all — picking a combination another
    /// app already holds is now the likeliest way for this to go wrong, and the user has to be
    /// told rather than left with a shortcut that silently does nothing. The text comes from the
    /// status itself, which names the shortcut that failed instead of assuming the default.
    ///
    /// `status` alone is not the whole truth: a failed change usually leaves the previous
    /// shortcut still registered, which is a very different situation from having no shortcut at
    /// all, so the row says which of the two it is.
    func updateHotkeyItem(for status: HotkeyRegistrationStatus) {
        guard !status.isRegistered else {
            hotkeyItem?.isHidden = true
            return
        }
        if let live = hotkey.activeShortcut {
            hotkeyItem?.title = "\(status.displayText) — still using \(live.displayString)"
        } else {
            hotkeyItem?.title = "\(status.displayText) — no capture shortcut is active"
        }
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

    /// Built on first use and retained: rebuilding it would discard the window's position and
    /// leave the previous one orphaned on screen. Shared by the status menu item and by ⌘,.
    @objc private func openSettingsWindow() {
        let controller = settingsWindowController ?? SettingsWindowController(settings: settings, hotkey: hotkey)
        settingsWindowController = controller
        // PLAN R-6, for the same reason the annotation window is not presented under test:
        // `show()` activates the app and takes key focus, which would pull the developer out of
        // whatever they are doing mid-run. The controller is still built and retained, so the
        // routing this method exists for is exercised.
        guard !Self.suppressesWindowPresentation else { return }
        controller.show()
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

    func annotationWindowDidRequestUpload(_ controller: AnnotationWindowController) {
        upload(from: controller)
    }

    func annotationWindowDidRequestSaveAs(_ controller: AnnotationWindowController) {
        saveAs(from: controller)
    }

    func annotationWindowDidCancel(_ controller: AnnotationWindowController) {
        AppLogger.annotation.info("Snapshot discarded without delivery")
        dismiss(controller)
    }
}
