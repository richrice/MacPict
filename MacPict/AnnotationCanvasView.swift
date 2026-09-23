import AppKit
import Combine
import CoreImage

/// Each text session owns its undo history; typing must never undo a crop or a shape.
@MainActor
private final class AnnotationTextView: NSTextView {
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }
}

/// A separate hit target above the text editor: grabbing it never selects characters.
@MainActor
private final class AnnotationMoveHandle: NSView {
    weak var canvas: AnnotationCanvasView?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
    override func draw(_ dirtyRect: NSRect) {
        let square = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.setFill()
        square.fill()
        NSColor.white.setStroke()
        square.lineWidth = 2
        square.stroke()
        let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                             accessibilityDescription: nil)!
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        symbol.withSymbolConfiguration(configuration)?.draw(in: bounds.insetBy(dx: 5, dy: 5))
    }
    override func mouseDown(with event: NSEvent) { canvas?.beginHandleDrag(with: event) }
    override func mouseDragged(with event: NSEvent) { canvas?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { canvas?.mouseUp(with: event) }
}

/// The drawing surface. Flipped, so it shares the image raster's top-left origin and
/// `CanvasGeometry` stays a pure scale-and-translate (PLAN D-1/D-2), and `AnnotationRenderer`
/// can draw the preview and the export with the same code.
///
/// The app has no menu bar, so every shortcut in PLAN §6 is handled here rather than by menu
/// item key equivalents.
@MainActor
final class AnnotationCanvasView: NSView {
    /// Wired by `AnnotationWindowController`; these are the keyboard paths out of the window.
    var onCopyImage: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onUpload: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCancel: (() -> Void)?
    var onInteractionHintChanged: ((String) -> Void)?

    /// A drag shorter than this in view points is a click that missed, not an annotation.
    private static let minimumDragExtent: CGFloat = 3

    /// Enough field to hold a caret when the click lands hard against the right edge and
    /// nothing has been typed yet; the first keystroke shifts the editor back inside.
    private static let minimumEditorWidth: CGFloat = 24

    /// The surround. Deliberately not black: a dark screenshot against a black letterbox was
    /// the reported bug, and lifting it off pure black gives the drop shadow something to fall
    /// on. It is not the boundary guarantee on its own — `drawImageBoundary` is.
    private static let letterboxFill = NSColor(white: 0.16, alpha: 1)

    private let document: AnnotationDocument
    private let baseImage: NSImage
    private var observers: Set<AnyCancellable> = []

    private struct Drag {
        let startImagePoint: CGPoint
        let startViewPoint: CGPoint
        var currentImagePoint: CGPoint
        /// Crop drags dim the surroundings and apply on mouse-up instead of appending.
        let isCrop: Bool
        /// True only for the crop *tool*, so a ⌘-drag never disturbs the tool selection.
        let revertsTool: Bool
        /// Fixed for the life of the drag, so the preview and the committed annotation are
        /// clamped identically and the shape cannot jump on mouse-up.
        let clampInset: CGFloat
    }

    private struct TextEditing {
        /// A bare `NSTextView`, not one inside an `NSScrollView`: the editor is a live preview
        /// of the committed annotation, and a preview that can scroll is one that can show text
        /// at a position the export will not. It is sized to its content instead, and it drives
        /// the same TextKit 1 objects `AnnotationRenderer` lays out with, so line breaks agree
        /// by construction rather than by a second implementation that has to be kept in step.
        let textView: NSTextView
        /// Top-left of the *view* in image pixels, captured when editing began. The glyphs sit
        /// `textOrigin` view points inside it, so this is not the committed annotation origin.
        let origin: CGPoint
        let style: AnnotationStyle
        let original: Annotation?
        let id: UUID
    }

    private struct AnnotationDrag {
        let original: Annotation
        let startViewPoint: CGPoint
        let startImagePoint: CGPoint
        var preview: Annotation
        var hasMoved = false
        var usesHandle = false
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private var hoveredAnnotationID: UUID?
    private var moveHandle: AnnotationMoveHandle?
    private var annotationDrag: AnnotationDrag?
    private var drag: Drag?
    private var textEditing: TextEditing?
    /// Restored after a crop-tool crop so cropping is never a mode the user has to escape.
    private var toolBeforeCrop: AnnotationTool
    private var lastTool: AnnotationTool

    init(document: AnnotationDocument) {
        self.document = document
        baseImage = NSImage(cgImage: document.image, size: document.imageSize)
        toolBeforeCrop = document.tool == .crop ? .arrow : document.tool
        lastTool = document.tool
        super.init(frame: .zero)

        document.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsDisplay = true
                    // A crop reached by keyboard (⇧⌘R, or ⌘Z over an earlier crop) changes
                    // `imageScale` and `displayRect` under a live editor. This notification
                    // arrives *before* the document has changed, so the refit is deferred to
                    // the next layout pass, which reads the settled value.
                    self?.needsLayout = true
                }
            }
            .store(in: &observers)
        document.$tool
            .sink { [weak self] tool in
                MainActor.assumeIsolated { self?.trackTool(tool) }
            }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationCanvasView is created in code only")
    }

    /// Load-bearing: puts the view in the image raster's coordinate space.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    /// The window is usually not key when it appears, and making the first click count is the
    /// difference between one gesture and two.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: CanvasGeometry {
        CanvasGeometry(imageSize: document.imageSize, sourceRect: document.cropRect, viewSize: bounds.size)
    }

    /// The pointer is the only thing telling the user which tool is armed while they are
    /// looking at the screenshot rather than the toolbar — and a capture now lands in crop
    /// mode, where an unannounced first drag would crop instead of draw.
    ///
    /// System cursors throughout, on evidence: SF-Symbol-badged crosshairs were rendered at
    /// real device pixels over white, black, grey and blue, and the badges turned to mush —
    /// crop unreadable, box and ellipse alike, line and arrow indistinguishable — while
    /// `NSCursor.crosshair` stayed crisp on every background. Crosshair is also what macOS's
    /// own ⌘⇧4 uses for exactly this gesture.
    static func cursor(for tool: AnnotationTool) -> NSCursor {
        switch tool {
        case .text: .iBeam
        case .move: .openHand
        case .crop, .arrow, .box, .ellipse, .line: .crosshair
        }
    }

    /// Whether a tool change should force the cursor immediately rather than waiting for the
    /// cursor rects to be re-evaluated. Pure so it can be tested; the AppKit plumbing around
    /// it cannot be exercised headlessly.
    static func shouldApplyCursorImmediately(pointerInView: CGPoint?, bounds: CGRect, isEditingText: Bool) -> Bool {
        // While an editor is up it owns the pointer's appearance; forcing ours would fight it.
        guard !isEditingText, let pointerInView else { return false }
        return bounds.contains(pointerInView)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.cursor(for: document.tool))
        if textEditing == nil, document.tool != .crop {
            for annotation in document.annotations {
                if let rect = textRect(for: annotation) {
                    let visible = rect.intersection(geometry.displayRect)
                    if !visible.isEmpty { addCursorRect(visible, cursor: .openHand) }
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateMoveHandle()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        if annotationDrag == nil { updateMoveHandle() }
    }

    private var movableAnnotations: [Annotation] {
        var annotations = document.annotations.filter { $0.id != textEditing?.id }
        if let editing = textEditing {
            let string = editedString(of: editing)
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let placement = placement(for: string, editing: editing, geometry: geometry)
                annotations.append(Annotation(id: editing.id,
                                              kind: .text(origin: placement.origin, string: string, wrapWidth: placement.wrapWidth),
                                              style: editing.style))
            }
        }
        if let moving = annotationDrag {
            annotations = annotations.map { $0.id == moving.original.id ? moving.preview : $0 }
        }
        return annotations
    }

    private func updateMoveHandle() {
        let annotations = movableAnnotations
        let target: Annotation?
        if let moving = annotationDrag, moving.usesHandle {
            target = moving.preview
        } else if let point = hoverPoint, bounds.contains(point) {
            // Include the path to the corner so the handle cannot vanish on approach.
            if let previous = annotations.first(where: { $0.id == hoveredAnnotationID }),
               let rect = moveTargetRect(for: previous),
               rect.union(handleRect(for: rect)).insetBy(dx: -3, dy: -3).contains(point) {
                target = previous
            } else {
                target = annotations.reversed().first { moveTargetRect(for: $0)?.contains(point) == true }
            }
        } else {
            target = nil
        }
        guard let target, let rect = moveTargetRect(for: target),
              rect.intersects(geometry.displayRect) else {
            hoveredAnnotationID = nil
            moveHandle?.removeFromSuperview()
            moveHandle = nil
            return
        }
        hoveredAnnotationID = target.id
        let handle = moveHandle ?? AnnotationMoveHandle()
        handle.canvas = self
        handle.identifier = NSUserInterfaceItemIdentifier("annotationMoveHandle")
        handle.toolTip = "Drag to move annotation"
        handle.setAccessibilityLabel("Move annotation")
        handle.frame = handleRect(for: rect)
        addSubview(handle, positioned: .above, relativeTo: nil)
        moveHandle = handle
        window?.invalidateCursorRects(for: handle)
    }

    private func handleRect(for textRect: CGRect) -> CGRect {
        let display = geometry.displayRect
        return CGRect(x: min(max(textRect.maxX - 12, display.minX), max(display.minX, display.maxX - 24)),
                      y: min(max(textRect.minY - 12, display.minY), max(display.minY, display.maxY - 24)),
                      width: 24, height: 24)
    }

    fileprivate func beginHandleDrag(with event: NSEvent) {
        guard let id = hoveredAnnotationID,
              let target = movableAnnotations.first(where: { $0.id == id }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Latch the gesture before committing so the handle remains above the editor
        // during teardown. Click count has no meaning on this dedicated move target.
        annotationDrag = AnnotationDrag(original: target, startViewPoint: point,
                            startImagePoint: geometry.imagePoint(fromView: point),
                            preview: target, usesHandle: true)
        commitTextEditing()
        guard let committed = document.annotations.first(where: { $0.id == id }) else {
            cancelAnnotationDrag()
            return
        }
        annotationDrag = AnnotationDrag(original: committed, startViewPoint: point,
                            startImagePoint: geometry.imagePoint(fromView: point),
                            preview: committed, usesHandle: true)
        window?.makeFirstResponder(self)
        updateMoveHandle()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        // Fixed tones, not semantic colours: this surface sits against arbitrary screenshot
        // pixels, so it must look the same in both appearances rather than track the system's.
        Self.letterboxFill.setFill()
        bounds.fill()

        let geometry = self.geometry
        let displayRect = geometry.displayRect
        guard !displayRect.isEmpty else { return }

        // Under the image, so the letterbox reads as a surround the image sits on rather than
        // as more image. The shadow alone is not the boundary guarantee — see the hairlines.
        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(rect: displayRect).fill()
        context.restoreGraphicsState()

        // Two verified facts drive this call: `from:` is in the image's bottom-left-origin
        // space (so the top-left-origin crop rect has to be flipped into it), and the plain
        // `draw(in:from:operation:fraction:)` overload ignores the context's flippedness and
        // would render the screenshot upside down. `respectFlipped:` is not optional here.
        let crop = document.cropRect
        let source = CGRect(
            x: crop.minX,
            y: document.imageSize.height - crop.maxY,
            width: crop.width,
            height: crop.height
        )
        baseImage.draw(
            in: displayRect,
            from: source,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )

        context.saveGraphicsState()
        NSBezierPath(rect: displayRect).setClip()
        // Annotations are stored against the full image, so shift the context to where the
        // full image's origin lands — that is what makes a crop need no annotation fix-up.
        let imageOrigin = geometry.viewPoint(fromImage: .zero)
        context.cgContext.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        let scale = 1 / geometry.imageScale
        let annotations = document.annotations
            .filter { $0.id != textEditing?.original?.id }
            .map { annotation in
                if let moving = annotationDrag, annotation.id == moving.original.id { return moving.preview }
                return annotation
            }
        AnnotationRenderer.draw(annotations, in: context, scale: scale)
        if let pending = inProgressAnnotation {
            AnnotationRenderer.draw(pending, in: context, scale: scale)
        }
        context.restoreGraphicsState()

        drawImageBoundary(displayRect)
        if document.tool == .move {
            context.saveGraphicsState()
            NSBezierPath(rect: displayRect).setClip()
            for annotation in annotations {
                guard let rect = moveTargetRect(for: annotation) else { continue }
                let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                NSColor.white.setStroke()
                border.lineWidth = 3
                border.stroke()
                NSColor.controlAccentColor.setStroke()
                border.lineWidth = 1.5
                border.stroke()
            }
            context.restoreGraphicsState()
        }

        if let drag, drag.isCrop {
            drawCropOverlay(for: drag, displayRect: displayRect, geometry: geometry)
        }
    }

    /// Where the drawable area stops. A drag begun in a letterbox band is clamped to the image
    /// edge, so the user needs to see that edge — and a flat surround cannot show it, because
    /// whatever tone it is, some screenshot ends in that tone (the reported bug was exactly a
    /// dark screenshot against a black surround).
    ///
    /// Two adjacent hairlines, light outside and dark inside: content can swallow one of them,
    /// never both. Verified by rendering the canvas against pure black, pure white and mid-grey
    /// test images.
    private func drawImageBoundary(_ displayRect: CGRect) {
        let outer = NSBezierPath(rect: displayRect.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        outer.stroke()

        let inner = NSBezierPath(rect: displayRect.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        inner.stroke()
    }

    /// The view's own size-change hook, and how a live editor keeps up with the geometry: a
    /// window resize or a crop changes `imageScale`, and an editor left at the scale in force
    /// when it opened would commit at a size the user was never shown.
    override func layout() {
        super.layout()
        if let textEditing { fitEditor(textEditing) }
        window?.invalidateCursorRects(for: self)
        updateMoveHandle()
    }

    override func mouseDown(with event: NSEvent) {
        // A click anywhere else commits the text being typed, and does nothing more.
        if textEditing != nil {
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)

        let geometry = self.geometry
        guard !geometry.displayRect.isEmpty else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let isCrop = event.modifierFlags.contains(.command) || document.tool == .crop
        let inset = clampInset(isCrop: isCrop)
        let imagePoint = imagePoint(for: viewPoint, geometry: geometry, inset: inset)

        let existing = document.tool == .move
            ? document.annotations.reversed().first(where: { moveTargetRect(for: $0)?.contains(viewPoint) == true })
            : textAnnotation(at: viewPoint)
        if !event.modifierFlags.contains(.command), let existing {
            if document.tool == .text || (event.clickCount == 2 && document.tool != .move) {
                editText(existing, with: event)
                return
            }
            if !isCrop {
                // Wait for mouse-up to distinguish a Text-tool click from a move.
                annotationDrag = AnnotationDrag(
                    original: existing,
                    startViewPoint: viewPoint,
                    startImagePoint: geometry.imagePoint(fromView: viewPoint),
                    preview: existing
                )
                return
            }
        }
        if !isCrop, document.tool == .text {
            beginTextEditing(at: imagePoint, geometry: geometry)
            return
        }
        guard isCrop || document.tool != .move else { return }
        drag = Drag(
            startImagePoint: imagePoint,
            startViewPoint: viewPoint,
            currentImagePoint: imagePoint,
            isCrop: isCrop,
            revertsTool: document.tool == .crop,
            clampInset: inset
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if annotationDrag != nil {
            updateAnnotationDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard let inset = drag?.clampInset else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        drag?.currentImagePoint = imagePoint(for: viewPoint, geometry: geometry, inset: inset)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if annotationDrag != nil {
            updateAnnotationDrag(at: convert(event.locationInWindow, from: nil))
            let finished = annotationDrag!
            annotationDrag = nil
            if finished.hasMoved {
                document.replace(finished.original.id, with: finished.preview)
            }
            hoverPoint = convert(event.locationInWindow, from: nil)
            if finished.usesHandle { updateMoveHandle() }
            needsDisplay = true
            refreshCursor(for: document.tool)
            return
        }
        guard let drag else { return }
        self.drag = nil
        needsDisplay = true

        let geometry = self.geometry
        let viewPoint = convert(event.locationInWindow, from: nil)
        let end = imagePoint(for: viewPoint, geometry: geometry, inset: drag.clampInset)

        // A click that missed is not a gesture whichever tool is selected, so it neither draws,
        // nor crops, nor hands the tool back. This guard has to sit above the crop branch:
        // `crop(to:)` rejects a sub-minimum rect on its own, but the tool revert below must not
        // fire for a stray click.
        let extent = max(
            abs(viewPoint.x - drag.startViewPoint.x),
            abs(viewPoint.y - drag.startViewPoint.y)
        )
        guard extent >= Self.minimumDragExtent else { return }

        if drag.isCrop {
            document.crop(to: rect(from: drag.startImagePoint, to: end))
            // Reverts on any completed crop-tool drag, deliberately not on whether the rect
            // changed: pixel alignment can land a genuine drag on the rect already in force,
            // and leaving the user in crop mode then is the exact trap §11.1 goal 2 forbids.
            if drag.revertsTool {
                document.tool = toolBeforeCrop
            }
            return
        }
        guard let annotation = annotation(from: drag.startImagePoint, to: end) else { return }
        document.append(annotation)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags.contains(.command) else { return false }
        cancelAnnotationDrag()
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if let editor = textEditing?.textView {
            if flags == [.command] {
                switch key {
                case "a": editor.selectAll(nil)
                case "c": editor.copy(nil)
                case "x": editor.cut(nil)
                case "v": editor.paste(nil)
                case "z": editor.breakUndoCoalescing(); editor.undoManager?.undo()
                case "\u{7f}": editor.deleteToBeginningOfLine(nil)
                default: break
                }
                if ["a", "c", "x", "v", "z", "\u{7f}"].contains(key) { return true }
            }
            if flags == [.command, .shift], key == "z" {
                editor.undoManager?.redo()
                return true
            }
        }

        if flags == [.command] {
            switch key {
            case "z": document.undo()
            case "w": onCancel?()
            case "\u{7f}": clearAnnotations()
            // Pending text is resolved by the controller's single delivery path, not here.
            case "\r", "\u{3}": onCopyImage?()
            // ⇧⌘S is the Save As shortcut, but a snapshot is an untitled document with nowhere
            // to save *back* to, so plain ⌘S can only mean the same thing — and a habitual ⌘S
            // that did nothing at all would be the worse answer.
            case "s": onSaveAs?()
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": document.redo()
            case "r": document.resetCrop()
            case "s": onSaveAs?()
            default: return false
            }
            return true
        }
        if flags == [.command, .option], key == "\r" || key == "\u{3}" {
            onCopyPath?()
            return true
        }
        if flags == [.command, .control], key == "\r" || key == "\u{3}" {
            onUpload?()
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard flags.isEmpty || flags == .shift else {
            super.keyDown(with: event)
            return
        }
        if let tool = AnnotationTool.allCases.first(where: { $0.keyEquivalent == key }) {
            document.tool = tool
            return
        }
        switch key {
        case "c": document.tool = .crop
        case "v": document.tool = .move
        case "[": document.cycleSize(forward: false)
        case "]": document.cycleSize(forward: true)
        // While a text field is being edited it owns Escape (see the delegate below), so
        // reaching here means there is nothing to cancel but the window itself.
        case "\u{1b}":
            if annotationDrag != nil { cancelAnnotationDrag() }
            else { onCancel?() }
        default: super.keyDown(with: event)
        }
    }

    private var inProgressAnnotation: Annotation? {
        guard let drag, !drag.isCrop else { return nil }
        return annotation(from: drag.startImagePoint, to: drag.currentImagePoint)
    }

    private func drawCropOverlay(for drag: Drag, displayRect: CGRect, geometry: CanvasGeometry) {
        let pending = geometry
            .viewRect(fromImage: rect(from: drag.startImagePoint, to: drag.currentImagePoint))
            .intersection(displayRect)
        // Dimming the surroundings is what turns a vague drag into a selection.
        let dim = NSBezierPath(rect: displayRect)
        dim.appendRect(pending)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        guard !pending.isEmpty else { return }
        let border = NSBezierPath(rect: pending)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
    }

    /// Clamps into the *visible* image, twice over: into `displayRect` in view space, and into
    /// `sourceRect` in image space. A point in a letterbox band must not become an annotation
    /// in the region the crop threw away — that annotation would never reach the export.
    private func imagePoint(for viewPoint: CGPoint, geometry: CanvasGeometry, inset: CGFloat) -> CGPoint {
        let display = geometry.displayRect
        let bounded = CGPoint(
            x: min(max(viewPoint.x, display.minX), display.maxX),
            y: min(max(viewPoint.y, display.minY), display.maxY)
        )
        return geometry.clampToSource(geometry.imagePoint(fromView: bounded), inset: inset)
    }

    /// Half the stroke width, so a path centred on the clamped point paints entirely inside the
    /// visible region instead of being cut flat by the crop: measured, a large arrow ending on
    /// the edge put ink 7 px past it.
    ///
    /// Zero for text, which is not stroked and whose extent clamping already bounds it, and zero
    /// for a crop — a crop rectangle is a selection, not a stroke, and cropping right up to the
    /// image edge is a thing people actually want.
    private func clampInset(isCrop: Bool) -> CGFloat {
        guard !isCrop else { return 0 }
        switch document.tool {
        case .arrow, .line, .box, .ellipse: return document.style.lineWidth / 2
        case .text, .crop, .move: return 0
        }
    }

    private func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    private func annotation(from: CGPoint, to: CGPoint) -> Annotation? {
        let style = document.style
        switch document.tool {
        case .arrow: return Annotation(kind: .arrow(from: from, to: to), style: style)
        case .line: return Annotation(kind: .line(from: from, to: to), style: style)
        case .box: return Annotation(kind: .box(rect(from: from, to: to)), style: style)
        case .ellipse: return Annotation(kind: .ellipse(rect(from: from, to: to)), style: style)
        case .text, .crop, .move: return nil
        }
    }

    private func trackTool(_ tool: AnnotationTool) {
        if tool != lastTool {
            cancelAnnotationDrag()
            commitTextEditing()
        }
        if tool == .crop, lastTool != .crop {
            toolBeforeCrop = lastTool
        }
        lastTool = tool
        refreshCursor(for: tool)
        updateInteractionHint(tool: tool)
    }

    var interactionHint: String { interactionHint(for: document.tool) }

    private func interactionHint(for tool: AnnotationTool) -> String {
        if textEditing != nil {
            return "Return: new line • Hover text, then drag its corner handle to move • ⌘↩: copy image"
        }
        switch tool {
        case .crop: return "Drag to crop • 1–5: annotate • ⌘↩: copy image, then paste into your agent"
        case .text: return "Click to add or edit text • Hover a note for its move handle • ⌘↩: copy image"
        case .move: return "Drag any outlined annotation to move • Text (5): edit text • ⌘Z: undo • ⌘↩: copy image"
        default: return "Hover annotations for a move handle • ⌘-drag: crop • ⌘↩: copy image"
        }
    }

    private func updateInteractionHint(tool: AnnotationTool? = nil) {
        onInteractionHintChanged?(interactionHint(for: tool ?? document.tool))
    }

    func undoAnnotation() {
        commitTextEditing()
        document.undo()
    }

    func redoAnnotation() {
        commitTextEditing()
        document.redo()
    }

    func clearAnnotations() {
        commitTextEditing()
        document.clear()
    }

    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        let inset = annotation.style.lineWidth / 2
        switch annotation.kind {
        case let .text(origin, string, width):
            return CGRect(origin: origin, size: AnnotationRenderer.textSize(for: string, style: annotation.style, maxWidth: width))
        case let .box(rect), let .ellipse(rect):
            return rect.standardized.insetBy(dx: -inset, dy: -inset)
        case let .line(from, to):
            return rect(from: from, to: to).insetBy(dx: -inset, dy: -inset)
        case let .arrow(from, to):
            var bounds = rect(from: from, to: to).insetBy(dx: -inset, dy: -inset)
            if let head = AnnotationRenderer.arrowHead(from: from, to: to, lineWidth: annotation.style.lineWidth) {
                bounds = bounds.union(rect(from: head.left, to: head.right))
            }
            return bounds
        }
    }

    private func moveTargetRect(for annotation: Annotation) -> CGRect? {
        let rect = geometry.viewRect(fromImage: annotationBounds(annotation))
        return rect.insetBy(dx: -max(8, (44 - rect.width) / 2),
                            dy: -max(8, (44 - rect.height) / 2))
    }

    private func textRect(for annotation: Annotation) -> CGRect? {
        guard case let .text(origin, string, wrapWidth) = annotation.kind else { return nil }
        let size = AnnotationRenderer.textSize(for: string, style: annotation.style, maxWidth: wrapWidth)
        let rect = geometry.viewRect(fromImage: CGRect(origin: origin, size: size))
        if document.tool == .move {
            // A whole note is a target, even when its glyphs are tiny at capture scale.
            return rect.insetBy(dx: -max(8, (44 - rect.width) / 2),
                                dy: -max(8, (44 - rect.height) / 2))
        }
        return rect.insetBy(dx: -4, dy: -4)
    }

    private func textAnnotation(at viewPoint: CGPoint) -> Annotation? {
        guard geometry.displayRect.contains(viewPoint) else { return nil }
        return document.annotations.reversed().first { textRect(for: $0)?.contains(viewPoint) == true }
    }

    private func editText(_ annotation: Annotation, with event: NSEvent) {
        beginTextEditing(at: .zero, geometry: geometry, original: annotation)
        if let editor = textEditing?.textView {
            let point = editor.convert(event.locationInWindow, from: nil)
            editor.setSelectedRange(NSRange(location: editor.characterIndexForInsertion(at: point), length: 0))
        }
    }

    private func updateAnnotationDrag(at viewPoint: CGPoint) {
        guard var moving = annotationDrag else { return }
        let extent = max(abs(viewPoint.x - moving.startViewPoint.x), abs(viewPoint.y - moving.startViewPoint.y))
        guard moving.hasMoved || extent >= Self.minimumDragExtent else { return }
        moving.hasMoved = true
        let point = geometry.imagePoint(fromView: viewPoint)
        let bounds = annotationBounds(moving.original)
        let crop = geometry.sourceRect
        let dx = max(crop.minX - bounds.minX, min(point.x - moving.startImagePoint.x, crop.maxX - bounds.maxX))
        let dy = max(crop.minY - bounds.minY, min(point.y - moving.startImagePoint.y, crop.maxY - bounds.maxY))
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + dx, y: point.y + dy) }
        switch moving.original.kind {
        case let .text(origin, string, width):
            moving.preview.kind = .text(origin: shifted(origin), string: string, wrapWidth: width)
        case let .line(from, to): moving.preview.kind = .line(from: shifted(from), to: shifted(to))
        case let .arrow(from, to): moving.preview.kind = .arrow(from: shifted(from), to: shifted(to))
        case let .box(rect): moving.preview.kind = .box(rect.offsetBy(dx: dx, dy: dy))
        case let .ellipse(rect): moving.preview.kind = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        }
        annotationDrag = moving
        NSCursor.closedHand.set()
        if moving.usesHandle { updateMoveHandle() }
        needsDisplay = true
    }

    private func cancelAnnotationDrag() {
        guard annotationDrag != nil else { return }
        annotationDrag = nil
        updateMoveHandle()
        needsDisplay = true
        refreshCursor(for: document.tool)
    }

    /// Invalidating the rects alone only takes effect the next time the pointer moves, so a
    /// tool picked with `1`…`6` or from the toolbar while the pointer already sits over the
    /// canvas would keep the previous cursor until the user jiggled the mouse. Setting it
    /// directly covers that case; the rect keeps it right on re-entry.
    private func refreshCursor(for tool: AnnotationTool) {
        window?.invalidateCursorRects(for: self)
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        guard Self.shouldApplyCursorImmediately(
            pointerInView: pointer,
            bounds: bounds,
            isEditingText: textEditing != nil
        ) else { return }
        if tool != .crop, let pointer, textAnnotation(at: pointer) != nil {
            NSCursor.openHand.set()
        } else {
            Self.cursor(for: tool).set()
        }
    }

    private func beginTextEditing(at imagePoint: CGPoint, geometry: CanvasGeometry, original: Annotation? = nil) {
        let style = original?.style ?? document.style
        var origin = imagePoint
        var string = ""
        if case let .text(anchor, text, _) = original?.kind {
            origin = anchor
            string = text
        }
        let textView = AnnotationTextView(frame: .zero)
        textView.font = AnnotationRenderer.font(for: style, scale: 1 / geometry.imageScale)
        textView.textColor = style.color.nsColor
        textView.insertionPointColor = style.color.nsColor
        // An `NSTextView` cannot draw in a blend mode, so the layer of the editor applies the
        // difference blend instead. The live text then shows inverted, the same as the render.
        if style.color.isInverse {
            textView.wantsLayer = true
            textView.layer?.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
        }
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel("Annotation text")
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        // `NSTextView` defaults this to 5, which would narrow the usable width by 10 points and
        // break lines earlier on screen than in the export. `AnnotationRenderer` zeroes it on
        // its own container for the same reason; the two have to match exactly.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.maximumNumberOfLines = 0
        // The container must NOT track the frame: the frame follows the text for display, and a
        // container that followed it too would be permanently exactly as wide as its own
        // content. `fitEditor` sets the container width explicitly instead.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.delegate = self

        textView.string = string
        let editing = TextEditing(textView: textView, origin: origin, style: style, original: original, id: original?.id ?? UUID())
        textEditing = editing
        addSubview(textView)
        fitEditor(editing)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        needsDisplay = true
        updateInteractionHint()
    }

    /// Where the glyphs actually go, in image pixels: the point the user clicked, pulled back
    /// so the *whole string* fits inside the visible crop. Clamping the origin alone bounded
    /// the anchor but not the extent, so a sentence begun legally near the right edge ran past
    /// it and the export cut it mid-phrase.
    ///
    /// `AnnotationRenderer.textSize` is the only measurement taken. Measuring the string a
    /// second way here would be a second thing that can disagree with what is drawn, which is
    /// this whole family of bugs.
    private func glyphOrigin(for string: String, editing: TextEditing, geometry: CanvasGeometry) -> CGPoint {
        placement(for: string, editing: editing, geometry: geometry).origin
    }

    /// Where the text goes and how wide it may run, in image pixels — the single decision the
    /// live editor and the commit both take, so the PNG cannot break lines anywhere other than
    /// the screen did.
    ///
    /// Wrapping is applied only when the text cannot fit as typed. Short annotations therefore
    /// behave exactly as they did before this existed: no wrap width, and the same
    /// shift-to-fit that keeps them whole against an edge.
    private func placement(
        for string: String,
        editing: TextEditing,
        geometry: CanvasGeometry
    ) -> (origin: CGPoint, wrapWidth: CGFloat?) {
        let inset = Self.textOrigin(of: editing.textView)
        let anchor = CGPoint(
            x: editing.origin.x + inset.x * geometry.imageScale,
            y: editing.origin.y + inset.y * geometry.imageScale
        )
        guard !string.isEmpty else { return (anchor, nil) }

        let source = geometry.sourceRect
        // Measured with no wrap first, which already honours the newlines the user typed.
        let natural = AnnotationRenderer.textSize(for: string, style: editing.style, maxWidth: nil)
        let previousWidth: CGFloat?
        if case let .text(_, _, width) = editing.original?.kind { previousWidth = width }
        else { previousWidth = nil }
        let wrapWidth: CGFloat? = previousWidth.map { min($0, source.width) }
            ?? (natural.width > source.width ? source.width : nil)
        let size = wrapWidth == nil
            ? natural
            : AnnotationRenderer.textSize(for: string, style: editing.style, maxWidth: wrapWidth)
        // Keep new wrapped notes at the crop's left edge, while reopened notes retain
        // their original anchor and wrapping even if the crop has since expanded.
        let x = wrapWidth != nil && previousWidth == nil ? source.minX
            : max(source.minX, min(anchor.x, max(source.minX, source.maxX - size.width)))
        // The vertical shift matters more now than it did: several lines can run off the bottom
        // where one line could not.
        let y = max(source.minY, min(anchor.y, max(source.minY, source.maxY - size.height)))
        return (CGPoint(x: x, y: y), wrapWidth)
    }

    /// Preserve indentation and blank lines exactly as entered.
    private func editedString(of editing: TextEditing) -> String {
        editing.textView.string
    }

    /// Places and sizes the editor for the geometry and the text in force *now*. Called again
    /// from `layout()` and on every keystroke, because the editor is a preview of the committed
    /// annotation and a preview drawn at a stale scale, or running past the crop, is a lie.
    private func fitEditor(_ editing: TextEditing) {
        let geometry = self.geometry
        let scale = 1 / geometry.imageScale
        let font = AnnotationRenderer.font(for: editing.style, scale: scale)
        editing.textView.font = font

        let string = editedString(of: editing)
        let placement = placement(for: string, editing: editing, geometry: geometry)
        let inset = Self.textOrigin(of: editing.textView)
        let glyph = geometry.viewPoint(fromImage: placement.origin)
        let size = AnnotationRenderer.textSize(
            for: string,
            style: editing.style,
            maxWidth: placement.wrapWidth
        )

        // Where lines break is the *container's* business, and the container width is never
        // derived from the text being laid out. A container sized to its own content is
        // permanently exactly full, so the next keystroke overflows it, wraps, and unwraps
        // again on the re-fit: measured, "The q" sat on two lines in the middle of a 300 pt
        // wide image, and typing on kept flipping between one line and two.
        //
        // Unwrapped text therefore gets an unbounded container — it cannot wrap by accident,
        // and a ⇧↩ still breaks because an explicit newline is not a wrap.
        //
        // Wrapped text keeps the width the renderer *used*, which is what makes the editor
        // break where the export breaks (at the preview's smaller font a word the renderer
        // rejected still fits inside the full allowed width — measured, an 8 % divergence).
        // That is safe here and not in the unwrapped case, and the difference is not
        // cosmetic: the used width is the longest line of a multi-line layout, so the line
        // being typed into has room, whereas a single line's own width leaves none at all.
        // Verified by typing the case in character by character: zero line-count reversals
        // with either width, so keeping break parity costs nothing.
        let containerWidth = placement.wrapWidth == nil
            ? CGFloat.greatestFiniteMagnitude
            : size.width * scale
        editing.textView.textContainer?.size = CGSize(
            width: containerWidth,
            height: .greatestFiniteMagnitude
        )

        // The frame is display only now, and follows the text the container has already laid
        // out, so it cannot feed back into line breaking. Read from the view's own layout
        // rather than re-measured, and given a caret's worth of slack so the insertion point
        // after a trailing space is not clipped.
        let laidOut = editing.textView.layoutManager.map { manager -> CGSize in
            if let container = editing.textView.textContainer {
                manager.ensureLayout(for: container)
                let used = manager.usedRect(for: container)
                // TextKit puts the caret after a trailing newline in an extra line fragment.
                return CGSize(width: used.width, height: max(used.maxY, manager.extraLineFragmentRect.maxY))
            }
            return .zero
        } ?? .zero
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = placement.wrapWidth == nil
            ? max(Self.minimumEditorWidth, ceil(max(laidOut.width, size.width * scale)) + lineHeight)
            : max(Self.minimumEditorWidth, containerWidth)
        let height = min(
            max(lineHeight, ceil(max(laidOut.height, size.height * scale))) + 4,
            max(lineHeight, geometry.displayRect.maxY - glyph.y)
        )
        editing.textView.frame = CGRect(
            x: glyph.x - inset.x,
            y: glyph.y - inset.y,
            width: width,
            height: height
        )
        updateMoveHandle()
    }

    /// Measured, not ported. The old `NSTextField` held its glyphs `cellSize.width / 2` inside
    /// the cell; `NSTextView` positions its text with `textContainerOrigin` plus the container's
    /// `lineFragmentPadding` instead, and that constant does not carry over. With the container
    /// inset and the padding both zeroed this reads (0, 0) — but it is read from the view rather
    /// than assumed, because anything non-zero here shifts every committed annotation.
    private static func textOrigin(of textView: NSTextView) -> CGPoint {
        let origin = textView.textContainerOrigin
        return CGPoint(x: origin.x + (textView.textContainer?.lineFragmentPadding ?? 0), y: origin.y)
    }

    /// Internal so the window controller's delivery path can resolve a half-typed label before
    /// the document is handed to the delegate. A no-op when nothing is being edited.
    func commitTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        let string = editedString(of: editing)
        // The same placement the editor was laying out with, recomputed against the geometry in
        // force now — so a resize or a crop mid-edit commits where the user was last shown the
        // text, and the wrap width stored on the annotation is exactly the one on screen.
        let placement = placement(for: string, editing: editing, geometry: geometry)
        endEditing(editing)
        let isBlank = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let original = editing.original {
            // Merely opening and closing a label must not move it or consume an undo step.
            if case let .text(_, previous, _) = original.kind, previous == string { return }
            document.replace(original.id, with: isBlank ? nil : Annotation(
                id: original.id,
                kind: .text(origin: placement.origin, string: string, wrapWidth: placement.wrapWidth),
                style: editing.style
            ))
        } else if !isBlank {
            document.append(Annotation(
                id: editing.id,
                kind: .text(origin: placement.origin, string: string, wrapWidth: placement.wrapWidth),
                style: editing.style
            ))
        }
    }

    /// Discards a half-typed label. A no-op when nothing is being edited.
    func cancelTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        endEditing(editing)
    }

    private func endEditing(_ editing: TextEditing) {
        // Detach first: tearing the editor down ends editing, which would otherwise re-enter.
        editing.textView.delegate = nil
        editing.textView.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        refreshCursor(for: document.tool)
        updateInteractionHint()
    }
}

extension AnnotationCanvasView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            // ⇧↩ starts a second line under the first. AppKit's own `insertLineBreak:` inserts
            // U+2028, which lays out identically but is a surprise to anything that later reads
            // the string, so a plain newline goes in instead.
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape cancels the edit and stops there: it must not close the window.
            cancelTextEditing()
            return true
        default:
            return false
        }
    }

    /// Re-places the editor on every keystroke: text that reaches the crop's edge pushes itself
    /// left rather than running off, and once it cannot fit at all it wraps — in both cases the
    /// editor has to be re-laid-out to keep showing what will actually be exported.
    func textDidChange(_ notification: Notification) {
        guard let textEditing else { return }
        fitEditor(textEditing)
    }

    func textDidEndEditing(_ notification: Notification) {
        // Any other way of losing focus — a toolbar click, say — commits what was typed.
        commitTextEditing()
    }
}
