import AppKit
import Combine
import SwiftUI

@MainActor
protocol AnnotationWindowDelegate: AnyObject {
    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController)
    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController)
    func annotationWindowDidRequestSaveAs(_ controller: AnnotationWindowController)
    func annotationWindowDidCancel(_ controller: AnnotationWindowController)
}

/// The app is an accessory with no menu bar, so the panel has to take key focus itself —
/// otherwise none of the shortcuts in PLAN §6 would ever be delivered.
private final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// PLAN §5.11 pins this as an `NSWindowController` subclass carrying
/// `let document: AnnotationDocument`. Those two are mutually exclusive: `NSWindowController`
/// already declares a settable `document: AnyObject?`, and Swift rejects a stored property,
/// an extension property, and a covariant read-only override of it alike. The pinned member
/// wins, since callers use it; `window` and `close()` are kept so the rest of the
/// `NSWindowController` surface a caller would reach for still resolves.
@MainActor
final class AnnotationWindowController: NSObject {
    struct PresentedError: Equatable {
        let title: String
        let detail: String
    }

    let document: AnnotationDocument
    weak var annotationDelegate: AnnotationWindowDelegate?

    private(set) var window: NSWindow?
    private(set) var lastPresentedError: PresentedError?

    private static let toolbarHeight: CGFloat = 44
    private static let screenInset: CGFloat = 40
    /// The toolbar's own fitting width was measured at 819 pt with the reset-crop control
    /// showing; the Save As button adds its 24 pt frame and the 4 pt that spaces it, so it now
    /// fits in 847. Below this it would start clipping its controls, so a tight crop
    /// letterboxes instead. The 23 pt of slack over the fitting width is deliberate.
    private static let minimumContentSize = CGSize(width: 870, height: 220)

    private enum Finish {
        case copyImage
        case copyPath
        case saveAs
        case cancel
    }

    private let targetScreen: NSScreen
    private let canvas: AnnotationCanvasView
    private var cropObserver: AnyCancellable?
    /// Latched when the window is *closed*, never when a finish action is merely requested:
    /// the controller cannot know whether the delegate's delivery succeeded, and a delivery
    /// that failed leaves the window standing so the user can retry (PLAN §7 Task 7).
    private var isClosed = false

    init(document: AnnotationDocument, screen: NSScreen) {
        self.document = document
        targetScreen = screen
        canvas = AnnotationCanvasView(document: document)

        let contentSize = Self.contentSize(for: document.outputSize, screen: screen)
        let panel = AnnotationPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window = panel
        super.init()

        panel.title = "MacPict"
        // .floating, not .statusBar/.screenSaver: those cover the menu bar.
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // The canvas needs every mouse drag, and a panel that vanishes when the user clicks
        // away is not a floating annotation window.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentMinSize = Self.minimumContentSize
        panel.delegate = self
        panel.contentView = makeContentView()
        panel.setFrame(centredFrame(contentSize: contentSize, in: panel), display: false)

        canvas.onCopyImage = { [weak self] in self?.deliver(.copyImage) }
        canvas.onCopyPath = { [weak self] in self?.deliver(.copyPath) }
        canvas.onSaveAs = { [weak self] in self?.deliver(.saveAs) }
        canvas.onCancel = { [weak self] in self?.deliver(.cancel) }

        // Observing the published rect rather than the crop handler is what makes undo and
        // redo of a crop resize the window too.
        cropObserver = document.$cropRect
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] rect in
                MainActor.assumeIsolated { self?.resize(forOutput: rect.size) }
            }
    }

    func present() {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Delivery errors belong to the window whose contents could not be delivered. Recording
    /// the value even when the window is not visible keeps the behavior testable without
    /// presenting UI from the test host.
    func presentError(title: String, detail: String) {
        lastPresentedError = PresentedError(title: title, detail: detail)
        guard let window, window.isVisible else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.beginSheetModal(for: window)
    }

    func close() {
        // Latch before the teardown so the `windowWillClose` that this triggers sees the
        // window as already closed and does not report a second, spurious cancel.
        guard !isClosed else { return }
        isClosed = true
        // A save panel can still be up — a new capture replaces this window whatever it is
        // doing. Ending the sheet first resumes whoever is awaiting the user's choice with a
        // cancel, rather than orphaning it on a window that is going away.
        if let sheet = window?.attachedSheet {
            window?.endSheet(sheet, returnCode: .cancel)
        }
        window?.close()
    }

    private func makeContentView() -> NSView {
        let container = NSView()
        let toolbar = NSHostingView(
            rootView: AnnotationToolbarView(
                document: document,
                onCopyImage: { [weak self] in self?.deliver(.copyImage) },
                onCopyPath: { [weak self] in self?.deliver(.copyPath) },
                onSaveAs: { [weak self] in self?.deliver(.saveAs) },
                onCancel: { [weak self] in self?.deliver(.cancel) }
            )
        )
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(canvas)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// Every user-initiated route out of this window — keyboard and toolbar alike — comes
    /// through here, so a half-typed label can never survive into the delegate's view of the
    /// document. A delivery commits it, because clicking Copy has to behave exactly like ⌘↩;
    /// a cancel discards it, because asking to throw the session away includes the sentence
    /// in progress. The fourth exit, a close this controller did not initiate, discards it in
    /// `windowWillClose` for the same reason.
    private func deliver(_ action: Finish) {
        switch action {
        case .copyImage, .copyPath, .saveAs: canvas.commitTextEditing()
        case .cancel: canvas.cancelTextEditing()
        }
        finish(action)
    }

    /// Deliberately does not latch: if the delegate fails to deliver it leaves the window
    /// open, and the user must be able to press ⌘↩ again. Only `close()` makes this inert.
    private func finish(_ action: Finish) {
        guard !isClosed else { return }
        switch action {
        case .copyImage: annotationDelegate?.annotationWindowDidRequestCopyImage(self)
        case .copyPath: annotationDelegate?.annotationWindowDidRequestCopyPath(self)
        case .saveAs: annotationDelegate?.annotationWindowDidRequestSaveAs(self)
        case .cancel: annotationDelegate?.annotationWindowDidCancel(self)
        }
    }

    private func resize(forOutput outputSize: CGSize) {
        guard let window else { return }
        let content = Self.contentSize(for: outputSize, screen: targetScreen)
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: content))
        // Centre-fixed and unanimated: a crop is an interaction step, and an animated resize
        // is latency the user can feel.
        frame.origin = CGPoint(
            x: window.frame.midX - frame.width / 2,
            y: window.frame.midY - frame.height / 2
        )
        window.setFrame(constrained(frame), display: true, animate: false)
    }

    private func centredFrame(contentSize: CGSize, in window: NSWindow) -> CGRect {
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize))
        let limit = targetScreen.visibleFrame
        frame.origin = CGPoint(x: limit.midX - frame.width / 2, y: limit.midY - frame.height / 2)
        return constrained(frame)
    }

    /// The window never exceeds the target screen's visible frame, and never sits off it.
    private func constrained(_ frame: CGRect) -> CGRect {
        let limit = targetScreen.visibleFrame
        var result = frame
        result.size.width = min(result.width, limit.width)
        result.size.height = min(result.height, limit.height)
        result.origin.x = min(max(result.minX, limit.minX), limit.maxX - result.width)
        result.origin.y = min(max(result.minY, limit.minY), limit.maxY - result.height)
        return result
    }

    private static func contentSize(for outputSize: CGSize, screen: NSScreen) -> CGSize {
        let available = screen.visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let maxCanvas = CGSize(
            width: max(available.width, minimumContentSize.width),
            height: max(available.height - toolbarHeight, minimumContentSize.height - toolbarHeight)
        )
        guard outputSize.width > 0, outputSize.height > 0 else {
            return CGSize(width: maxCanvas.width, height: maxCanvas.height + toolbarHeight)
        }
        // Capped at the image's natural point size: a 200 px crop blown up to fill the screen
        // would be a worse view of it, not a better one.
        let naturalScale = 1 / max(screen.backingScaleFactor, 1)
        let scale = min(
            maxCanvas.width / outputSize.width,
            maxCanvas.height / outputSize.height,
            naturalScale
        )
        return CGSize(
            width: max(outputSize.width * scale, minimumContentSize.width),
            height: max(outputSize.height * scale + toolbarHeight, minimumContentSize.height)
        )
    }
}

extension AnnotationWindowController: NSWindowDelegate {
    /// A close the controller did not initiate — the red button — still has to tell the
    /// coordinator to let go of this controller. Latching first makes the delegate's own
    /// `close()` a no-op rather than a second trip through here.
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        // The fourth exit, and it resolves pending text like the other three: a close nobody
        // asked this controller for is a cancel, so a half-typed label is discarded rather
        // than left alive in a window that is going away.
        canvas.cancelTextEditing()
        annotationDelegate?.annotationWindowDidCancel(self)
    }
}
