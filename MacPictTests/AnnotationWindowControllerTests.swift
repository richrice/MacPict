import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import MacPict

@MainActor
private final class RecordingWindowDelegate: AnnotationWindowDelegate {
    enum Message: Equatable {
        case copyImage
        case copyPath
        case cancel
    }

    private(set) var messages: [Message] = []
    /// What the document looked like *at the moment* each message arrived — the coordinator
    /// exports from this, so anything not committed by then is lost for good.
    private(set) var textsWhenNotified: [[String]] = []
    /// The coordinator closes the window after a delivery that succeeded and leaves it
    /// standing after one that threw, so both halves are modelled here.
    var closesOnCopy = false
    var closesOnCancel = false

    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController) {
        record(.copyImage, controller)
        if closesOnCopy { controller.close() }
    }

    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController) {
        record(.copyPath, controller)
        if closesOnCopy { controller.close() }
    }

    func annotationWindowDidCancel(_ controller: AnnotationWindowController) {
        record(.cancel, controller)
        if closesOnCancel { controller.close() }
    }

    private func record(_ message: Message, _ controller: AnnotationWindowController) {
        messages.append(message)
        textsWhenNotified.append(controller.document.annotations.compactMap { annotation in
            if case let .text(_, string) = annotation.kind { return string }
            return nil
        })
    }
}

/// The window is never presented: `present()` activates the app and would steal focus from
/// whoever is running the tests. Everything here drives the real key path instead.
@MainActor
final class AnnotationWindowControllerTests: XCTestCase {
    private var delegate: RecordingWindowDelegate!
    private var controller: AnnotationWindowController!

    override func setUp() async throws {
        try await super.setUp()
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        delegate = RecordingWindowDelegate()
        controller = AnnotationWindowController(document: AnnotationDocument(image: try makeImage()), screen: screen)
        controller.annotationDelegate = delegate
    }

    override func tearDown() async throws {
        controller?.annotationDelegate = nil
        controller?.close()
        controller = nil
        delegate = nil
        try await super.tearDown()
    }

    private func makeImage() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 120,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        return try XCTUnwrap(context.makeImage())
    }

    private func canvas() throws -> AnnotationCanvasView {
        let subviews = try XCTUnwrap(controller.window?.contentView?.subviews)
        return try XCTUnwrap(subviews.compactMap { $0 as? AnnotationCanvasView }.first)
    }

    private func keyEvent(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }

    private func pressCopyImage() throws {
        _ = try canvas().performKeyEquivalent(with: keyEvent("\r", .command))
    }

    private func pressCopyPath() throws {
        _ = try canvas().performKeyEquivalent(with: keyEvent("\r", [.command, .option]))
    }

    private func pressCloseWindow() throws {
        _ = try canvas().performKeyEquivalent(with: keyEvent("w", .command))
    }

    private func pressEscape() throws {
        try canvas().keyDown(with: keyEvent("\u{1b}", []))
    }

    /// The real toolbar's own closures, read off the hosting view, so this exercises the
    /// wiring rather than a copy of it.
    private func toolbar() throws -> AnnotationToolbarView {
        let subviews = try XCTUnwrap(controller.window?.contentView?.subviews)
        let hosting = try XCTUnwrap(subviews.compactMap { $0 as? NSHostingView<AnnotationToolbarView> }.first)
        return hosting.rootView
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// Points are in window coordinates, as a real `NSEvent`'s would be.
    private func drag(from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        let canvas = try canvas()
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: from, modifiers))
        canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: to, modifiers))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: to, modifiers))
    }

    private func windowPoint(fromCanvas point: CGPoint) throws -> CGPoint {
        try canvas().convert(point, to: nil)
    }

    private func selectCropTool() throws {
        try canvas().keyDown(with: keyEvent("6", []))
        XCTAssertEqual(controller.document.tool, .crop)
    }

    /// Types into the inline editor without pressing Return, the way a user does just before
    /// reaching for the mouse.
    @discardableResult
    private func beginTextEdit(_ string: String) throws -> NSTextField {
        controller.window?.layoutIfNeeded()
        let canvas = try canvas()
        XCTAssertFalse(canvas.geometry.displayRect.isEmpty, "canvas needs a real size to place the editor")
        controller.document.tool = .text
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = string
        XCTAssertTrue(committedTexts().isEmpty, "the text must still be uncommitted at this point")
        return field
    }

    private func committedTexts() -> [String] {
        controller.document.annotations.compactMap { annotation in
            if case let .text(_, string) = annotation.kind { return string }
            return nil
        }
    }

    /// The regression guard: a delivery that throws leaves the window open by design, and an
    /// open window the user cannot retry from is worse than no window at all.
    func testCopyImageWhoseDelegateDoesNotCloseLeavesTheControllerLiveForARetry() throws {
        delegate.closesOnCopy = false

        try pressCopyImage()
        try pressCopyImage()

        XCTAssertEqual(delegate.messages, [.copyImage, .copyImage])
    }

    func testEveryActionKeepsWorkingWhileTheDelegateDeclinesToClose() throws {
        delegate.closesOnCopy = false
        delegate.closesOnCancel = false

        try pressCopyImage()
        try pressCopyPath()
        try pressEscape()
        try pressCloseWindow()

        XCTAssertEqual(delegate.messages, [.copyImage, .copyPath, .cancel, .cancel])
    }

    func testControllerIsInertOnceTheDelegateHasClosedIt() throws {
        delegate.closesOnCopy = true

        try pressCopyImage()
        XCTAssertEqual(delegate.messages, [.copyImage])

        try pressCopyImage()
        try pressCopyPath()
        try pressCloseWindow()
        try pressEscape()

        XCTAssertEqual(delegate.messages, [.copyImage])
    }

    func testUserInitiatedCloseReportsCancelExactlyOnce() throws {
        delegate.closesOnCancel = false

        controller.window?.close()

        XCTAssertEqual(delegate.messages, [.cancel])
    }

    /// The recursion the coordinator actually creates: red button → `windowWillClose` →
    /// `…DidCancel` → the coordinator's `close()` → teardown. Exactly one cancel, no loop.
    func testUserInitiatedCloseWhoseDelegateCallsCloseReportsCancelExactlyOnce() throws {
        delegate.closesOnCancel = true

        controller.window?.close()

        XCTAssertEqual(delegate.messages, [.cancel])
    }

    /// The other direction of the same recursion: ⌘W → `…DidCancel` → `close()` →
    /// `windowWillClose`, which must not report a second cancel.
    func testKeyboardCancelWhoseDelegateCallsCloseReportsCancelExactlyOnce() throws {
        delegate.closesOnCancel = true

        try pressCloseWindow()

        XCTAssertEqual(delegate.messages, [.cancel])
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    /// The regression guard for Repair 3 item 1. `crop(to:)` aligns rects outward to whole
    /// pixels, so two nearly identical drags can produce the same rect — and a revert
    /// conditioned on the rect *changing* would silently strand the user in crop mode, which
    /// is the mode trap PLAN §11.1 goal 2 exists to prevent.
    func testCropToolDragProducingAnUnchangedRectStillRestoresThePreviousTool() throws {
        controller.window?.layoutIfNeeded()
        controller.document.tool = .box
        try selectCropTool()
        let before = controller.document.cropRect

        // Across the whole visible image: clamped to the display rect, this aligns to exactly
        // the crop already in force.
        try drag(from: CGPoint(x: -500, y: -500), to: CGPoint(x: 5000, y: 5000))

        XCTAssertEqual(controller.document.cropRect, before, "the test only means anything if the rect is unchanged")
        XCTAssertEqual(controller.document.tool, .box)
    }

    func testCropToolDragAppliesTheCropAndRestoresThePreviousTool() throws {
        controller.window?.layoutIfNeeded()
        controller.document.tool = .line
        try selectCropTool()
        let display = try canvas().geometry.displayRect
        let from = try windowPoint(fromCanvas: CGPoint(x: display.minX + display.width * 0.25, y: display.minY + display.height * 0.25))
        let to = try windowPoint(fromCanvas: CGPoint(x: display.maxX - display.width * 0.25, y: display.maxY - display.height * 0.25))

        try drag(from: from, to: to)

        XCTAssertTrue(controller.document.isCropped)
        XCTAssertEqual(controller.document.tool, .line)
    }

    /// The other half of dropping the rect-changed condition: a stray click is not a gesture,
    /// so it must neither crop nor hand the tool back.
    func testCropToolClickWithoutADragLeavesTheCropAndTheToolAlone() throws {
        controller.window?.layoutIfNeeded()
        controller.document.tool = .box
        try selectCropTool()
        let before = controller.document.cropRect
        let point = try windowPoint(fromCanvas: CGPoint(x: 60, y: 60))
        let canvas = try canvas()

        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: point))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: point.x + 1, y: point.y - 1)))

        XCTAssertEqual(controller.document.cropRect, before)
        XCTAssertEqual(controller.document.tool, .crop)
    }

    /// The regression guard for Repair 2. Reaching for the toolbar instead of pressing Return
    /// must not lose the sentence that explains what is wrong with the screenshot — and the
    /// delegate has to see it, since that is the document it exports from.
    func testToolbarCopyImageCommitsPendingTextBeforeNotifyingTheDelegate() throws {
        try beginTextEdit("this button is misaligned")

        try toolbar().onCopyImage()

        XCTAssertEqual(committedTexts(), ["this button is misaligned"])
        XCTAssertEqual(delegate.messages, [.copyImage])
        XCTAssertEqual(delegate.textsWhenNotified, [["this button is misaligned"]])
    }

    func testToolbarCopyPathCommitsPendingTextBeforeNotifyingTheDelegate() throws {
        try beginTextEdit("check this label")

        try toolbar().onCopyPath()

        XCTAssertEqual(committedTexts(), ["check this label"])
        XCTAssertEqual(delegate.messages, [.copyPath])
        XCTAssertEqual(delegate.textsWhenNotified, [["check this label"]])
    }

    /// Guards the refactor that moved the commit out of the key handler and into the
    /// controller's single delivery path: ⌘↩ must still behave identically.
    func testKeyboardCopyImageStillCommitsPendingText() throws {
        try beginTextEdit("keyboard note")

        try pressCopyImage()

        XCTAssertEqual(delegate.textsWhenNotified, [["keyboard note"]])
    }

    func testKeyboardCopyPathStillCommitsPendingText() throws {
        try beginTextEdit("keyboard path note")

        try pressCopyPath()

        XCTAssertEqual(delegate.textsWhenNotified, [["keyboard path note"]])
    }

    /// Chosen semantics: an explicit cancel discards the half-typed label rather than
    /// committing it. Cancel means "throw this session away", and that includes the sentence
    /// in progress.
    func testCancelDiscardsPendingTextRatherThanCommittingIt() throws {
        try beginTextEdit("never meant to keep this")

        try toolbar().onCancel()

        XCTAssertEqual(committedTexts(), [])
        XCTAssertEqual(delegate.messages, [.cancel])
        XCTAssertEqual(delegate.textsWhenNotified, [[]])
        XCTAssertTrue(try canvas().subviews.isEmpty, "the editor should be torn down by a cancel")
    }

    func testKeyboardCancelDiscardsPendingText() throws {
        try beginTextEdit("also discarded")

        try pressCloseWindow()

        XCTAssertEqual(committedTexts(), [])
        XCTAssertEqual(delegate.textsWhenNotified, [[]])
    }

    func testWhitespaceOnlyPendingTextIsNotCommittedByADelivery() throws {
        try beginTextEdit("   ")

        try toolbar().onCopyImage()

        XCTAssertEqual(controller.document.annotations.count, 0)
        XCTAssertEqual(delegate.textsWhenNotified, [[]])
        // Without this the test passes whether the commit ran and trimmed to nothing or never
        // ran at all, which is no test of the trim rule.
        XCTAssertTrue(try canvas().subviews.isEmpty, "the editor must be torn down even when the trimmed text is empty")
    }

    /// A close this controller did not initiate is still an exit, and must resolve pending text
    /// like the other three rather than leaving an editor alive in a window that is going away.
    func testSystemInitiatedCloseWhileTypingTearsDownTheEditor() throws {
        try beginTextEdit("half typed")

        controller.window?.close()

        XCTAssertEqual(delegate.messages, [.cancel])
        XCTAssertEqual(committedTexts(), [])
        XCTAssertEqual(delegate.textsWhenNotified, [[]])
        XCTAssertTrue(try canvas().subviews.isEmpty)
    }

    /// A successful delivery is still one-shot: the close that follows it must not turn into
    /// a cancel the coordinator would act on.
    func testSuccessfulCopyFollowedByCloseReportsNoCancel() throws {
        delegate.closesOnCopy = true

        try pressCopyImage()

        XCTAssertEqual(delegate.messages, [.copyImage])
        XCTAssertFalse(delegate.messages.contains(.cancel))
    }
}
