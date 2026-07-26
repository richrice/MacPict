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
        case saveAs
        case cancel
    }

    private(set) var messages: [Message] = []
    /// What the document looked like *at the moment* each message arrived — the coordinator
    /// exports from this, so anything not committed by then is lost for good.
    private(set) var textsWhenNotified: [[String]] = []
    /// The coordinator closes the window after a delivery that succeeded and leaves it
    /// standing after one that threw, so both halves are modelled here.
    var closesOnDelivery = false
    var closesOnCancel = false

    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController) {
        record(.copyImage, controller)
        if closesOnDelivery { controller.close() }
    }

    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController) {
        record(.copyPath, controller)
        if closesOnDelivery { controller.close() }
    }

    /// Save As closes on a write that succeeded, exactly like the two copy routes — and unlike
    /// them it also does nothing at all when the user cancels the panel, which is the
    /// `closesOnDelivery == false` case.
    func annotationWindowDidRequestSaveAs(_ controller: AnnotationWindowController) {
        record(.saveAs, controller)
        if closesOnDelivery { controller.close() }
    }

    func annotationWindowDidCancel(_ controller: AnnotationWindowController) {
        record(.cancel, controller)
        if closesOnCancel { controller.close() }
    }

    private func record(_ message: Message, _ controller: AnnotationWindowController) {
        messages.append(message)
        textsWhenNotified.append(controller.document.annotations.compactMap { annotation in
            if case let .text(_, string, _) = annotation.kind { return string }
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

    private func makeImage(width: Int = 120, height: Int = 80) throws -> CGImage {
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
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

    private func pressSaveAs() throws {
        _ = try canvas().performKeyEquivalent(with: keyEvent("s", [.command, .shift]))
    }

    private func pressPlainSave() throws {
        _ = try canvas().performKeyEquivalent(with: keyEvent("s", .command))
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
    private func beginTextEdit(_ string: String) throws -> NSTextView {
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
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = string
        XCTAssertTrue(committedTexts().isEmpty, "the text must still be uncommitted at this point")
        return editor
    }

    private func committedTexts() -> [String] {
        controller.document.annotations.compactMap { annotation in
            if case let .text(_, string, _) = annotation.kind { return string }
            return nil
        }
    }

    /// The regression guard: a delivery that throws leaves the window open by design, and an
    /// open window the user cannot retry from is worse than no window at all.
    func testCopyImageWhoseDelegateDoesNotCloseLeavesTheControllerLiveForARetry() throws {
        delegate.closesOnDelivery = false

        try pressCopyImage()
        try pressCopyImage()

        XCTAssertEqual(delegate.messages, [.copyImage, .copyImage])
    }

    func testEveryActionKeepsWorkingWhileTheDelegateDeclinesToClose() throws {
        delegate.closesOnDelivery = false
        delegate.closesOnCancel = false

        try pressCopyImage()
        try pressCopyPath()
        try pressSaveAs()
        try pressEscape()
        try pressCloseWindow()

        XCTAssertEqual(delegate.messages, [.copyImage, .copyPath, .saveAs, .cancel, .cancel])
    }

    func testControllerIsInertOnceTheDelegateHasClosedIt() throws {
        delegate.closesOnDelivery = true

        try pressCopyImage()
        XCTAssertEqual(delegate.messages, [.copyImage])

        try pressCopyImage()
        try pressCopyPath()
        try pressSaveAs()
        try pressCloseWindow()
        try pressEscape()

        XCTAssertEqual(delegate.messages, [.copyImage])
    }

    // MARK: - Save As

    /// Cancelling the save panel leaves the window standing, so the shortcut has to keep working
    /// afterwards — a Save As you can only attempt once is worse than none.
    func testSaveAsStaysAvailableAfterADelegateThatDoesNotClose() throws {
        delegate.closesOnDelivery = false

        try pressSaveAs()
        try pressSaveAs()

        XCTAssertEqual(delegate.messages, [.saveAs, .saveAs])
    }

    /// A snapshot has nowhere to save back to, so plain ⌘S can only mean Save As. Both spellings
    /// reach the same single route out.
    func testPlainCommandSReachesTheSameSaveAsRouteAsShiftCommandS() throws {
        delegate.closesOnDelivery = false

        try pressPlainSave()
        try pressSaveAs()

        XCTAssertEqual(delegate.messages, [.saveAs, .saveAs])
    }

    func testToolbarSaveAsCommitsPendingTextBeforeNotifyingTheDelegate() throws {
        try beginTextEdit("save this note too")

        try toolbar().onSaveAs()

        XCTAssertEqual(committedTexts(), ["save this note too"])
        XCTAssertEqual(delegate.messages, [.saveAs])
        XCTAssertEqual(delegate.textsWhenNotified, [["save this note too"]])
    }

    func testKeyboardSaveAsStillCommitsPendingText() throws {
        try beginTextEdit("keyboard save note")

        try pressSaveAs()

        XCTAssertEqual(delegate.textsWhenNotified, [["keyboard save note"]])
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

    /// A crop narrower than the canvas letterboxes, and a drag begun in one of those bands must
    /// land inside the crop — an annotation in the discarded region never reaches the export.
    func testDragStartedInALetterboxBandStaysInsideTheCrop() throws {
        controller.window?.layoutIfNeeded()
        let document = controller.document
        // Tall and narrow inside a wide canvas: guaranteed bands left and right.
        document.crop(to: CGRect(x: 40, y: 0, width: 24, height: 80))
        let canvas = try canvas()
        let display = canvas.geometry.displayRect
        XCTAssertGreaterThan(display.minX, 4, "this test needs a real letterbox band to drag from")
        document.tool = .arrow

        try drag(
            from: try windowPoint(fromCanvas: CGPoint(x: display.minX / 2, y: display.midY)),
            to: try windowPoint(fromCanvas: CGPoint(x: display.maxX + display.minX / 2, y: display.midY - 20))
        )

        let kind = try XCTUnwrap(document.annotations.last?.kind)
        guard case let .arrow(from, to) = kind else { return XCTFail("expected an arrow, got \(kind)") }
        for point in [from, to] {
            XCTAssertTrue(
                document.cropRect.insetBy(dx: -0.5, dy: -0.5).contains(point),
                "\(point) is outside the visible crop \(document.cropRect)"
            )
        }
    }

    /// The property the user actually cares about: the arrow they drew is in the image the
    /// agent receives, rather than in the part the crop threw away.
    func testAnnotationDrawnFromTheLetterboxBandSurvivesTheExport() throws {
        controller.window?.layoutIfNeeded()
        let document = controller.document
        document.crop(to: CGRect(x: 40, y: 0, width: 24, height: 80))
        let canvas = try canvas()
        let display = canvas.geometry.displayRect
        document.tool = .box
        document.style = AnnotationStyle(color: .red, size: .large)

        // Entirely inside the left band, and stopping in the middle of it rather than at its
        // edge — a stroke this thick would otherwise bleed across the boundary and mark the
        // crop even when the geometry is wrong, which is not what this is testing. Clamped,
        // the drag collapses onto the crop's left edge and marks the image; unclamped it lands
        // wholly in the discarded region and the agent receives an unmarked image.
        XCTAssertGreaterThan(display.minX, 120, "this test needs a wide band to stay clear of the stroke")
        try drag(
            from: try windowPoint(fromCanvas: CGPoint(x: display.minX * 0.1, y: display.minY + 10)),
            to: try windowPoint(fromCanvas: CGPoint(x: display.minX * 0.5, y: display.maxY - 10))
        )
        XCTAssertEqual(document.annotations.count, 1)

        let exported = try SnapshotExporter.flatten(
            image: document.image,
            annotations: document.annotations,
            cropRect: document.cropRect
        )
        XCTAssertEqual(exported.width, Int(document.cropRect.width))
        XCTAssertEqual(exported.height, Int(document.cropRect.height))
        XCTAssertTrue(containsRedInk(exported), "the annotation is missing from the exported image")
    }

    /// Measured, not assumed: the committed origin is the field's frame shifted right by the
    /// glyph inset, which put it 2 pt past a `sourceRect` ending at x=250 before this was
    /// clamped. A text annotation outside the crop is invisible in the export.
    func testTextPlacedAtTheImageEdgeCommitsInsideTheCrop() throws {
        controller.window?.layoutIfNeeded()
        let document = controller.document
        document.crop(to: CGRect(x: 40, y: 0, width: 24, height: 80))
        let canvas = try canvas()
        let display = canvas.geometry.displayRect
        document.tool = .text

        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: try windowPoint(
            fromCanvas: CGPoint(x: display.maxX, y: display.midY)
        )))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "edge"
        canvas.commitTextEditing()

        let kind = try XCTUnwrap(document.annotations.last?.kind)
        guard case let .text(origin, _, _) = kind else { return XCTFail("expected text, got \(kind)") }
        XCTAssertLessThanOrEqual(origin.x, document.cropRect.maxX, "text origin escaped the crop")
        XCTAssertGreaterThanOrEqual(origin.x, document.cropRect.minX)
    }

    /// The setUp document is 120×80, far too small to hold a 24 px font, so every string would
    /// be wider than the image and the interesting cases would collapse into the pinned one.
    private func useLargeDocument() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        controller.annotationDelegate = nil
        controller.close()
        delegate = RecordingWindowDelegate()
        controller = AnnotationWindowController(
            document: AnnotationDocument(image: try makeImage(width: 1200, height: 800)),
            screen: screen
        )
        controller.annotationDelegate = delegate
        controller.window?.layoutIfNeeded()
    }

    /// Bounds of the annotation-coloured ink in an exported image, in that image's pixels.
    private func redInkBounds(_ image: CGImage, rows: Range<Int>? = nil) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { raw -> (Int, Int, Int, Int)? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            let scanned = rows.map { $0.clamped(to: 0..<height) } ?? 0..<height
            for y in scanned {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    guard bytes[offset] > 150, bytes[offset + 1] < 90, bytes[offset + 2] < 90 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return minX <= maxX ? (minX, maxX, minY, maxY) : nil
        }
    }

    /// Ink bounds within a band of rows, for comparing one rendered line against another.
    private func exportedInkRows(
        of document: AnnotationDocument,
        rows: Range<Int>
    ) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let exported = try SnapshotExporter.flatten(
            image: document.image,
            annotations: document.annotations,
            cropRect: document.cropRect
        )
        return redInkBounds(exported, rows: rows)
    }

    private func exportedInk(of document: AnnotationDocument) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let exported = try SnapshotExporter.flatten(
            image: document.image,
            annotations: document.annotations,
            cropRect: document.cropRect
        )
        XCTAssertEqual(exported.width, Int(document.cropRect.width))
        XCTAssertEqual(exported.height, Int(document.cropRect.height))
        return try XCTUnwrap(redInkBounds(exported), "no annotation ink reached the exported image")
    }

    /// Redrawn into a layout this test controls rather than read raw: the exporter's own
    /// bitmap is premultiplied-first little-endian, and reading its bytes positionally made an
    /// opaque pixel's alpha look like a bright channel — which matched every pixel and made
    /// this check pass on any image at all.
    private func containsRedInk(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                // AnnotationColor.red is sRGB (1.0, 0.20, 0.20); the base image is flat grey.
                if bytes[offset] > 150, bytes[offset + 1] < 90, bytes[offset + 2] < 90 { return true }
            }
            return false
        }
    }

    /// The user's actual complaint: every mode showed the plain arrow, so nothing said which
    /// tool was armed.
    func testNoToolShowsThePlainArrowCursor() {
        for tool in AnnotationTool.allCases {
            XCTAssertFalse(
                AnnotationCanvasView.cursor(for: tool) === NSCursor.arrow,
                "\(tool) still shows the default arrow"
            )
        }
    }

    func testCropAndShapeToolsUseTheCrosshairAndTextUsesTheIBeam() {
        XCTAssertTrue(AnnotationCanvasView.cursor(for: .crop) === NSCursor.crosshair)
        for tool in [AnnotationTool.arrow, .box, .ellipse, .line] {
            XCTAssertTrue(AnnotationCanvasView.cursor(for: tool) === NSCursor.crosshair, "\(tool)")
        }
        XCTAssertTrue(AnnotationCanvasView.cursor(for: .text) === NSCursor.iBeam)
    }

    /// The "tool changed while the pointer is already inside" rule. The AppKit half — that
    /// `.set()` reaches the window server — is not assertable headlessly; this covers the
    /// decision it is driven by.
    func testCursorIsForcedOnlyWhenThePointerIsInsideAndNoEditorIsUp() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertTrue(AnnotationCanvasView.shouldApplyCursorImmediately(
            pointerInView: CGPoint(x: 100, y: 50), bounds: bounds, isEditingText: false
        ))
        XCTAssertFalse(AnnotationCanvasView.shouldApplyCursorImmediately(
            pointerInView: CGPoint(x: 400, y: 50), bounds: bounds, isEditingText: false
        ), "a pointer outside the canvas must be left alone")
        XCTAssertFalse(AnnotationCanvasView.shouldApplyCursorImmediately(
            pointerInView: nil, bounds: bounds, isEditingText: false
        ), "no window means no pointer to reason about")
        XCTAssertFalse(AnnotationCanvasView.shouldApplyCursorImmediately(
            pointerInView: CGPoint(x: 100, y: 50), bounds: bounds, isEditingText: true
        ), "a live text editor owns the pointer's appearance")
    }

    /// Changing the tool with the keyboard must leave a cursor rect that matches the new tool,
    /// and it must cover the canvas only — the toolbar keeps the ordinary arrow.
    func testKeyboardToolChangeLeavesTheCanvasCursorRectMatchingTheNewTool() throws {
        controller.window?.layoutIfNeeded()
        let canvas = try canvas()

        try canvas.keyDown(with: keyEvent("5", []))
        XCTAssertEqual(controller.document.tool, .text)
        canvas.resetCursorRects()
        XCTAssertTrue(AnnotationCanvasView.cursor(for: controller.document.tool) === NSCursor.iBeam)

        try canvas.keyDown(with: keyEvent("6", []))
        XCTAssertEqual(controller.document.tool, .crop)
        canvas.resetCursorRects()
        XCTAssertTrue(AnnotationCanvasView.cursor(for: controller.document.tool) === NSCursor.crosshair)

        let toolbar = try XCTUnwrap(controller.window?.contentView?.subviews.first { !($0 is AnnotationCanvasView) })
        XCTAssertFalse(canvas.bounds.isEmpty)
        XCTAssertFalse(canvas.frame.intersects(toolbar.frame), "the canvas cursor rect must not reach the toolbar")
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

    // MARK: - Text extent inside the crop

    private static let edgeText = "This cannot"

    /// Types `string` starting near a chosen corner of the visible crop and returns the ink
    /// the export ends up with. The click sits deliberately close to the edge, so a placement
    /// that only bounds the origin runs the string off the image.
    private func exportedInkForTextNear(_ anchor: CGPoint, crop: CGRect, string: String) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let document = controller.document
        document.crop(to: crop)
        document.style = AnnotationStyle(color: .red, size: .small)
        try beginTextEdit(string, atImagePoint: anchor)
        try canvas().commitTextEditing()
        XCTAssertEqual(committedTexts(), [string])
        return try exportedInk(of: document)
    }

    /// The reported bug: text typed near the right edge of a cropped snapshot came out of the
    /// export cut off mid-phrase. The assertion is on the exported pixels, and the yardstick is
    /// the same string placed comfortably inside — if the edge case is truncated its ink is
    /// narrower, no matter what the coordinates say.
    func testTextTypedNearTheRightEdgeIsWholeInTheExport() throws {
        try useLargeDocument()
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)

        let interior = try exportedInkForTextNear(CGPoint(x: 200, y: 200), crop: crop, string: Self.edgeText)
        let interiorWidth = interior.maxX - interior.minX

        try useLargeDocument()
        let edge = try exportedInkForTextNear(CGPoint(x: crop.maxX - 30, y: 200), crop: crop, string: Self.edgeText)

        XCTAssertEqual(edge.maxX - edge.minX, interiorWidth, accuracy: 2, "the string was truncated at the right edge")
        XCTAssertLessThan(edge.maxX, Int(crop.width) - 1, "the text should come to rest against the edge, not run off it")
    }

    func testTextTypedNearTheBottomEdgeIsWholeInTheExport() throws {
        try useLargeDocument()
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)

        let interior = try exportedInkForTextNear(CGPoint(x: 200, y: 200), crop: crop, string: Self.edgeText)
        let interiorHeight = interior.maxY - interior.minY

        try useLargeDocument()
        let edge = try exportedInkForTextNear(CGPoint(x: 200, y: crop.maxY - 8), crop: crop, string: Self.edgeText)

        XCTAssertEqual(edge.maxY - edge.minY, interiorHeight, accuracy: 2, "the string was clipped at the bottom edge")
        XCTAssertLessThan(edge.maxY, Int(crop.height) - 1, "the text should come to rest against the edge, not run off it")
    }

    /// Superseded by wrapping. Until this feature an over-wide string clipped at the crop edge,
    /// and this test asserted exactly that; now it wraps instead, so the property worth pinning
    /// is that the editor and the export wrap in the *same* places. Same failure mode, new
    /// behaviour — the assertion was replaced rather than relaxed.
    func testOverWideStringWrapsAtTheSameBreaksInEditorAndExport() throws {
        try useLargeDocument()
        let document = controller.document
        let crop = CGRect(x: 100, y: 100, width: 220, height: 300)
        document.crop(to: crop)
        document.style = AnnotationStyle(color: .red, size: .small)
        let canvas = try canvas()

        try beginTextEdit("far wider than this narrow crop can ever hold", atImagePoint: CGPoint(x: 110, y: 150))
        let editorInk = try redInk(of: canvas)
        let scale = canvas.geometry.imageScale
        let editorBlock = CGSize(width: editorInk.width * scale, height: editorInk.height * scale)

        canvas.commitTextEditing()
        guard case let .text(_, _, wrapWidth)? = document.annotations.last?.kind else {
            return XCTFail("expected a text annotation")
        }
        XCTAssertEqual(wrapWidth, crop.width, "an over-wide string should wrap to the visible width")

        let ink = try exportedInk(of: document)
        let exportBlock = CGSize(width: CGFloat(ink.maxX - ink.minX), height: CGFloat(ink.maxY - ink.minY))

        // A moved word changes the block width by 8 % or more; laying the same words out at the
        // preview's smaller font changes it by about 3 %, because glyph advances are not linear
        // in point size. The tolerance sits between the two, so this fails on a different break
        // and tolerates the metric difference that is inherent to how the renderer draws.
        let ratio = editorBlock.width / exportBlock.width
        XCTAssertEqual(ratio, 1.0, accuracy: 0.05, "editor and export broke lines differently")
        XCTAssertLessThanOrEqual(exportBlock.width, crop.width, "wrapped text must not exceed the visible width")

        let oneLine = AnnotationRenderer.textSize(for: "x", style: document.style, maxWidth: nil).height
        XCTAssertGreaterThan(exportBlock.height, oneLine * 2, "the string should have wrapped onto three lines")
        XCTAssertEqual(
            CGFloat(ink.maxY - ink.minY),
            AnnotationRenderer.textSize(for: "far wider than this narrow crop can ever hold", style: document.style, maxWidth: crop.width).height,
            accuracy: oneLine,
            "the export wrapped to a different number of lines than the renderer's own layout"
        )
    }

    // MARK: - Stroke inset at the crop edge

    /// Ink bounds over the **full** image, not the cropped export. Flattening with the crop can
    /// only ever report ink inside it, so it cannot tell a complete shape from one the crop cut
    /// flat; measuring the full image shows the ink that would have been lost.
    private func fullImageInk(of document: AnnotationDocument) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let flattened = try SnapshotExporter.flatten(
            image: document.image,
            annotations: document.annotations,
            cropRect: nil
        )
        return try XCTUnwrap(redInkBounds(flattened), "no annotation ink was drawn at all")
    }

    private func dragPastTheCorner(of crop: CGRect, tool: AnnotationTool, size: AnnotationSize) throws {
        let document = controller.document
        document.crop(to: crop)
        document.tool = tool
        document.style = AnnotationStyle(color: .red, size: size)
        controller.window?.layoutIfNeeded()
        let geometry = try canvas().geometry
        try drag(
            from: try windowPoint(fromCanvas: geometry.viewPoint(fromImage: CGPoint(x: crop.minX + 40, y: crop.minY + 30))),
            to: try windowPoint(fromCanvas: geometry.viewPoint(fromImage: CGPoint(x: crop.maxX + 80, y: crop.maxY + 80)))
        )
        XCTAssertEqual(document.annotations.count, 1, "the drag should have produced one annotation")
    }

    /// A stroke is centred on its path, so a path clamped to the crop edge painted half its
    /// width past it and the export cut it flat: measured at 2, 4 and 7 px for the three sizes.
    func testStrokedShapesDraggedPastTheEdgeKeepAllTheirInkInsideTheCrop() throws {
        let crop = CGRect(x: 100, y: 100, width: 400, height: 300)
        for tool in [AnnotationTool.arrow, .box, .line, .ellipse] {
            for size in AnnotationSize.allCases {
                try useLargeDocument()
                try dragPastTheCorner(of: crop, tool: tool, size: size)

                let ink = try fullImageInk(of: controller.document)
                XCTAssertLessThanOrEqual(CGFloat(ink.maxX) + 1, crop.maxX, "\(tool) \(size) ink ran past the right edge")
                XCTAssertLessThanOrEqual(CGFloat(ink.maxY) + 1, crop.maxY, "\(tool) \(size) ink ran past the bottom edge")
                XCTAssertGreaterThanOrEqual(CGFloat(ink.minX), crop.minX, "\(tool) \(size) ink ran past the left edge")
                XCTAssertGreaterThanOrEqual(CGFloat(ink.minY), crop.minY, "\(tool) \(size) ink ran past the top edge")
            }
        }
    }

    /// The same shape, cropped and uncropped, must contain the same ink — nothing was lost to
    /// the crop, which is the property the user actually reported.
    func testNothingIsLostToTheCropWhenAShapeIsDraggedPastTheEdge() throws {
        let crop = CGRect(x: 100, y: 100, width: 400, height: 300)
        try useLargeDocument()
        try dragPastTheCorner(of: crop, tool: .arrow, size: .large)

        let full = try fullImageInk(of: controller.document)
        let exported = try exportedInk(of: controller.document)

        XCTAssertEqual(exported.minX, full.minX - Int(crop.minX))
        XCTAssertEqual(exported.maxX, full.maxX - Int(crop.minX))
        XCTAssertEqual(exported.minY, full.minY - Int(crop.minY))
        XCTAssertEqual(exported.maxY, full.maxY - Int(crop.minY))
    }

    /// Text is not stroked, so the inset must not reach it. Two sizes with very different line
    /// widths at the same anchor: a leaked stroke inset would move the second one.
    func testTextPlacementIsUnaffectedByTheStrokeInset() throws {
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        let anchor = CGPoint(x: 200, y: 200)

        var origins: [CGPoint] = []
        for size in [AnnotationSize.small, .large] {
            try useLargeDocument()
            controller.document.crop(to: crop)
            controller.document.style = AnnotationStyle(color: .red, size: size)
            try beginTextEdit("edge", atImagePoint: anchor)
            try canvas().commitTextEditing()
            guard case let .text(origin, _, _)? = controller.document.annotations.last?.kind else {
                return XCTFail("expected a text annotation")
            }
            origins.append(origin)
        }

        XCTAssertEqual(origins[0], origins[1], "the stroke inset leaked into the text path")
        XCTAssertEqual(origins[0], anchor, "text should still commit exactly where it was clicked")
    }

    /// The inset only bites at the edge: a shape drawn with room to spare is where it was drawn.
    func testShapeDrawnComfortablyInsideIsUnmoved() throws {
        try useLargeDocument()
        let document = controller.document
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        document.crop(to: crop)
        document.tool = .arrow
        document.style = AnnotationStyle(color: .red, size: .large)
        controller.window?.layoutIfNeeded()
        let geometry = try canvas().geometry
        let start = CGPoint(x: 250, y: 250)
        let finish = CGPoint(x: 450, y: 350)

        try drag(
            from: try windowPoint(fromCanvas: geometry.viewPoint(fromImage: start)),
            to: try windowPoint(fromCanvas: geometry.viewPoint(fromImage: finish))
        )

        guard case let .arrow(from, to)? = document.annotations.last?.kind else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(from.x, start.x, accuracy: 1)
        XCTAssertEqual(from.y, start.y, accuracy: 1)
        XCTAssertEqual(to.x, finish.x, accuracy: 1)
        XCTAssertEqual(to.y, finish.y, accuracy: 1)
    }

    // MARK: - Progressive typing

    /// Types one character at a time, the way a person does, and reports the editor's line
    /// count after each keystroke. Every other test in this file sets a whole string at once,
    /// which is exactly why a per-keystroke oscillation shipped unnoticed.
    private func lineCountsWhileTyping(_ string: String, into editor: NSTextView) -> [Int] {
        string.map { character in
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            guard let manager = editor.layoutManager else { return -1 }
            var count = 0
            var index = 0
            while index < manager.numberOfGlyphs {
                var range = NSRange()
                _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
                count += 1
                index = NSMaxRange(range)
            }
            return count
        }
    }

    /// The reported regression: typing in the middle of the image, with room to spare, wrapped
    /// onto a second line as soon as a word was finished and flipped back on the next keystroke.
    func testTypingMidImageNeverWrapsOrChangesLineCount() throws {
        try useLargeDocument()
        let document = controller.document
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        document.crop(to: crop)
        document.style = AnnotationStyle(color: .red, size: .small)

        let editor = try beginTextEdit("", atImagePoint: CGPoint(x: crop.midX - 100, y: crop.midY))
        let counts = lineCountsWhileTyping("The quick brown", into: editor)

        XCTAssertEqual(Set(counts), [1], "text with room to spare must stay on one line: \(counts)")
    }

    /// Wrapping, when it is genuinely needed, must only ever add lines as the text grows. A
    /// count that goes back down is the container fighting its own content.
    func testTypingIntoANarrowCropOnlyEverAddsLines() throws {
        try useLargeDocument()
        let document = controller.document
        document.crop(to: CGRect(x: 100, y: 100, width: 220, height: 300))
        document.style = AnnotationStyle(color: .red, size: .small)

        let editor = try beginTextEdit("", atImagePoint: CGPoint(x: 110, y: 150))
        let counts = lineCountsWhileTyping("far wider than this narrow crop can ever hold", into: editor)

        XCTAssertEqual(counts, counts.sorted(), "the line count went back down while typing: \(counts)")
        XCTAssertGreaterThan(counts.last ?? 0, 1, "this string is meant to wrap")
    }

    /// The two ways text reaches the editor must not drift apart: whatever progressive typing
    /// produces, setting the same string in one go has to produce as well.
    func testTypedAndSetAllAtOnceProduceTheSameCommittedAnnotation() throws {
        let string = "The quick brown fox"
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        let anchor = CGPoint(x: crop.midX - 100, y: crop.midY)

        try useLargeDocument()
        controller.document.crop(to: crop)
        controller.document.style = AnnotationStyle(color: .red, size: .small)
        let editor = try beginTextEdit("", atImagePoint: anchor)
        _ = lineCountsWhileTyping(string, into: editor)
        try canvas().commitTextEditing()
        let typed = try XCTUnwrap(controller.document.annotations.last?.kind)
        let typedInk = try exportedInk(of: controller.document)

        try useLargeDocument()
        controller.document.crop(to: crop)
        controller.document.style = AnnotationStyle(color: .red, size: .small)
        try beginTextEdit(string, atImagePoint: anchor)
        try canvas().commitTextEditing()
        let atOnce = try XCTUnwrap(controller.document.annotations.last?.kind)
        let atOnceInk = try exportedInk(of: controller.document)

        XCTAssertEqual(typed, atOnce, "typing and setting the string produced different annotations")
        XCTAssertEqual(typedInk.minX, atOnceInk.minX)
        XCTAssertEqual(typedInk.maxX, atOnceInk.maxX)
        XCTAssertEqual(typedInk.maxY - typedInk.minY, atOnceInk.maxY - atOnceInk.minY)
    }

    /// An explicit break is not a wrap: the unbounded container must not swallow ⇧↩.
    func testShiftReturnStillBreaksWhileTypingProgressively() throws {
        try useLargeDocument()
        let document = controller.document
        document.crop(to: CGRect(x: 100, y: 100, width: 600, height: 400))
        document.style = AnnotationStyle(color: .red, size: .small)
        let canvas = try canvas()

        let editor = try beginTextEdit("", atImagePoint: CGPoint(x: 200, y: 200))
        _ = lineCountsWhileTyping("Hello", into: editor)
        XCTAssertTrue(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        let counts = lineCountsWhileTyping("World", into: editor)

        XCTAssertEqual(Set(counts), [2], "an explicit line break must survive the unbounded container")
        canvas.commitTextEditing()
        XCTAssertEqual(committedTexts(), ["Hello\nWorld"])
    }

    // MARK: - Multi-line text

    /// Literally what the user asked for: a few words, ⇧↩, and more text underneath the start
    /// of the first line.
    func testShiftReturnStartsASecondLineUnderTheFirst() throws {
        try useLargeDocument()
        let document = controller.document
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        document.crop(to: crop)
        document.style = AnnotationStyle(color: .red, size: .small)
        let canvas = try canvas()

        let editor = try beginTextEdit("Hello", atImagePoint: CGPoint(x: 200, y: 200))
        XCTAssertTrue(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        editor.insertText("World", replacementRange: editor.selectedRange())
        canvas.commitTextEditing()

        XCTAssertEqual(committedTexts(), ["Hello\nWorld"])
        let ink = try exportedInk(of: document)
        let midpoint = (ink.minY + ink.maxY) / 2
        let first = try XCTUnwrap(exportedInkRows(of: document, rows: ink.minY..<midpoint))
        let second = try XCTUnwrap(exportedInkRows(of: document, rows: midpoint..<(ink.maxY + 1)))

        XCTAssertEqual(second.minX, first.minX, accuracy: 2, "the second line must start under the first")
        XCTAssertGreaterThan(ink.maxY - ink.minY,
                             Int(AnnotationRenderer.textSize(for: "Hello", style: document.style).height),
                             "two lines should be taller than one")
    }

    /// The fast path: Return commits, and must not leave a newline in the string.
    func testReturnCommitsAndDoesNotInsertANewline() throws {
        try useLargeDocument()
        controller.document.crop(to: CGRect(x: 100, y: 100, width: 600, height: 400))
        let canvas = try canvas()

        let editor = try beginTextEdit("one line", atImagePoint: CGPoint(x: 200, y: 200))
        XCTAssertTrue(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        XCTAssertEqual(committedTexts(), ["one line"])
        XCTAssertTrue(canvas.subviews.isEmpty, "Return should have committed and torn the editor down")
    }

    /// Short text must not start reflowing just because wrapping now exists.
    func testShortTextNearAnEdgeIsNotWrapped() throws {
        try useLargeDocument()
        let document = controller.document
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)
        document.crop(to: crop)
        document.style = AnnotationStyle(color: .red, size: .small)

        try beginTextEdit("This can", atImagePoint: CGPoint(x: crop.maxX - 30, y: 200))
        try canvas().commitTextEditing()

        guard case let .text(origin, _, wrapWidth)? = document.annotations.last?.kind else {
            return XCTFail("expected a text annotation")
        }
        XCTAssertNil(wrapWidth, "text that fits must carry no wrap width")
        XCTAssertGreaterThan(origin.x, crop.minX, "short text should stay where it was typed, not jump to the left edge")
    }

    func testMultiLineTextOverflowingTheBottomShiftsUpAndIsWholeInTheExport() throws {
        let lines = "alpha\nbravo\ncharlie\ndelta"
        try useLargeDocument()
        let crop = CGRect(x: 100, y: 100, width: 600, height: 400)

        controller.document.crop(to: crop)
        controller.document.style = AnnotationStyle(color: .red, size: .small)
        try beginTextEdit(lines, atImagePoint: CGPoint(x: 200, y: 150))
        try canvas().commitTextEditing()
        let interior = try exportedInk(of: controller.document)

        try useLargeDocument()
        controller.document.crop(to: crop)
        controller.document.style = AnnotationStyle(color: .red, size: .small)
        try beginTextEdit(lines, atImagePoint: CGPoint(x: 200, y: crop.maxY - 20))
        try canvas().commitTextEditing()
        let edge = try exportedInk(of: controller.document)

        XCTAssertEqual(edge.maxY - edge.minY, interior.maxY - interior.minY, accuracy: 2,
                       "the block was clipped at the bottom instead of shifting up")
        XCTAssertLessThan(edge.maxY, Int(crop.height) - 1, "the text should come to rest against the edge, not run off it")
    }

    /// `NSTextView` defaults `lineFragmentPadding` to 5, which would narrow the editor's usable
    /// width by 10 points and break lines earlier on screen than in the export.
    func testEditorLineFragmentPaddingAndInsetAreZero() throws {
        try useLargeDocument()
        let editor = try beginTextEdit("padding", atImagePoint: CGPoint(x: 200, y: 200))

        XCTAssertEqual(editor.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(editor.textContainerInset, .zero)
        XCTAssertEqual(editor.textContainerOrigin, .zero, "a non-zero text origin shifts every committed annotation")
    }

    // MARK: - Editor / render parity (Repair 4)

    /// The bounding box, in view points, of everything the canvas drew in the annotation
    /// colour — the glyphs, whether they came from the live `NSTextView` or from
    /// `AnnotationRenderer`. `cacheDisplay` includes subviews, so one measurement covers both.
    /// Red (1, 0.2, 0.2) over a 0.3 grey screenshot on black, so "much more red than green"
    /// isolates the text and nothing else.
    private func redInk(of view: NSView) throws -> CGRect {
        view.window?.layoutIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        var samples = [Int](repeating: 0, count: 5)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&samples, atX: x, y: y)
                guard samples[alphaFirst ? 1 : 0] - samples[alphaFirst ? 2 : 1] > 64 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else {
            XCTFail("no annotation-coloured pixels were drawn at all")
            return .null
        }
        // `colorAt`/`getPixel` are top-left origin, as is the flipped canvas, so the only
        // conversion needed is out of the bitmap's backing scale and into view points.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// Opens the inline editor at a chosen point in *image* pixels, leaving room for the
    /// glyphs inside the visible image so neither render is clipped by `displayRect`.
    @discardableResult
    private func beginTextEdit(_ string: String, atImagePoint imagePoint: CGPoint) throws -> NSTextView {
        controller.window?.layoutIfNeeded()
        let canvas = try canvas()
        XCTAssertFalse(canvas.geometry.displayRect.isEmpty, "canvas needs a real size to place the editor")
        controller.document.tool = .text
        let viewPoint = canvas.geometry.viewPoint(fromImage: imagePoint)
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: try windowPoint(fromCanvas: viewPoint)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first, "the text view is what the user types into and what draws the preview")
        editor.insertText(string, replacementRange: NSRange(location: 0, length: 0))
        return editor
    }

    /// The regression guard for the reported "text moves when I hit Enter". The editor holds
    /// its glyphs a couple of points inside the cell; `AnnotationRenderer` puts the layout box's
    /// corner on the annotation origin. The measurement is the assertion: the same glyphs are
    /// photographed off the canvas before and after the commit, and the two boxes have to
    /// coincide. Nothing here re-derives the offset the fix applies.
    func testCommittedTextLandsWhereTheEditorDrewIt() throws {
        let canvas = try canvas()
        try beginTextEdit("Hxy", atImagePoint: CGPoint(x: 10, y: 10))

        let editorInk = try redInk(of: canvas)
        canvas.commitTextEditing()
        XCTAssertEqual(committedTexts(), ["Hxy"])
        let renderedInk = try redInk(of: canvas)

        XCTAssertEqual(renderedInk.minX, editorInk.minX, accuracy: 1, "committed glyphs moved horizontally")
        XCTAssertEqual(renderedInk.minY, editorInk.minY, accuracy: 1, "committed glyphs moved vertically")
        XCTAssertEqual(renderedInk.width, editorInk.width, accuracy: 1)
        XCTAssertEqual(renderedInk.height, editorInk.height, accuracy: 1)
    }

    /// Item 2: the editor's font was fixed when editing began, so a window resize mid-edit left
    /// it previewing one size and committing another. Same photograph-and-compare, with the
    /// geometry changed under the live edit — and the resize is asserted to have actually moved
    /// the scale, so the test cannot pass by the resize being a no-op.
    func testTextEditLiveAcrossAResizeCommitsAtTheSizeTheEditorWasShowing() throws {
        let canvas = try canvas()
        try beginTextEdit("Hxy", atImagePoint: CGPoint(x: 10, y: 10))
        let scaleBefore = canvas.geometry.imageScale
        let inkBefore = try redInk(of: canvas)

        controller.window?.setContentSize(CGSize(width: 1000, height: 400))
        controller.window?.layoutIfNeeded()
        XCTAssertNotEqual(canvas.geometry.imageScale, scaleBefore, accuracy: 0.001, "the resize has to change the scale or the test proves nothing")

        let editorInk = try redInk(of: canvas)
        XCTAssertGreaterThan(editorInk.height, inkBefore.height * 1.2, "the editor must have grown with the canvas")
        canvas.commitTextEditing()
        let renderedInk = try redInk(of: canvas)

        XCTAssertEqual(renderedInk.minX, editorInk.minX, accuracy: 1)
        XCTAssertEqual(renderedInk.minY, editorInk.minY, accuracy: 1)
        XCTAssertEqual(renderedInk.width, editorInk.width, accuracy: 1)
        XCTAssertEqual(renderedInk.height, editorInk.height, accuracy: 1)
    }

    /// A crop *is* reachable while an edit is live — a crop drag commits the text first, but
    /// ⇧⌘R and ⌘Z are key equivalents that reach the canvas whatever holds first responder.
    func testTextEditLiveAcrossACropCommitsAtTheSizeTheEditorWasShowing() throws {
        controller.window?.layoutIfNeeded()
        let canvas = try canvas()
        controller.document.crop(to: CGRect(x: 0, y: 0, width: 60, height: 40))
        controller.window?.layoutIfNeeded()

        try beginTextEdit("Hxy", atImagePoint: CGPoint(x: 6, y: 6))
        let scaleBefore = canvas.geometry.imageScale

        _ = canvas.performKeyEquivalent(with: try keyEvent("r", [.command, .shift]))
        XCTAssertFalse(controller.document.isCropped, "the crop reset has to land while the edit is live")
        controller.window?.layoutIfNeeded()
        XCTAssertNotEqual(canvas.geometry.imageScale, scaleBefore, accuracy: 0.001, "the reset has to change the scale or the test proves nothing")

        let editorInk = try redInk(of: canvas)
        canvas.commitTextEditing()
        let renderedInk = try redInk(of: canvas)

        XCTAssertEqual(renderedInk.minX, editorInk.minX, accuracy: 1)
        XCTAssertEqual(renderedInk.minY, editorInk.minY, accuracy: 1)
        XCTAssertEqual(renderedInk.width, editorInk.width, accuracy: 1)
        XCTAssertEqual(renderedInk.height, editorInk.height, accuracy: 1)
    }

    /// A successful delivery is still one-shot: the close that follows it must not turn into
    /// a cancel the coordinator would act on.
    func testSuccessfulCopyFollowedByCloseReportsNoCancel() throws {
        delegate.closesOnDelivery = true

        try pressCopyImage()

        XCTAssertEqual(delegate.messages, [.copyImage])
        XCTAssertFalse(delegate.messages.contains(.cancel))
    }
}
