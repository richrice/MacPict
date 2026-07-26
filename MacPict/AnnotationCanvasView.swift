import AppKit
import Combine

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
    var onCancel: (() -> Void)?

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
    }

    private struct TextEditing {
        let field: NSTextField
        /// Top-left of the *field* in image pixels, captured when editing began. The glyphs sit
        /// `textInset` view points to its right, so this is not the committed annotation origin.
        let origin: CGPoint
        let style: AnnotationStyle
        /// View points between the field's leading edge and its first glyph.
        let textInset: CGFloat
    }

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
                    if self?.textEditing != nil { self?.needsLayout = true }
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
        AnnotationRenderer.draw(document.annotations, in: context, scale: scale)
        if let pending = inProgressAnnotation {
            AnnotationRenderer.draw(pending, in: context, scale: scale)
        }
        context.restoreGraphicsState()

        drawImageBoundary(displayRect)

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
        let imagePoint = imagePoint(for: viewPoint, geometry: geometry)
        let isCrop = event.modifierFlags.contains(.command) || document.tool == .crop

        if !isCrop, document.tool == .text {
            beginTextEditing(at: imagePoint, geometry: geometry)
            return
        }
        drag = Drag(
            startImagePoint: imagePoint,
            startViewPoint: viewPoint,
            currentImagePoint: imagePoint,
            isCrop: isCrop,
            revertsTool: document.tool == .crop
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        drag?.currentImagePoint = imagePoint(for: viewPoint, geometry: geometry)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        needsDisplay = true

        let geometry = self.geometry
        let viewPoint = convert(event.locationInWindow, from: nil)
        let end = imagePoint(for: viewPoint, geometry: geometry)

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
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if flags == [.command] {
            switch key {
            case "z": document.undo()
            case "w": onCancel?()
            case "\u{7f}": document.clear()
            // Pending text is resolved by the controller's single delivery path, not here.
            case "\r": onCopyImage?()
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": document.redo()
            case "r": document.resetCrop()
            default: return false
            }
            return true
        }
        if flags == [.command, .option], key == "\r" {
            onCopyPath?()
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
        case "[": document.cycleSize(forward: false)
        case "]": document.cycleSize(forward: true)
        // While a text field is being edited it owns Escape (see the delegate below), so
        // reaching here means there is nothing to cancel but the window itself.
        case "\u{1b}": onCancel?()
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
    private func imagePoint(for viewPoint: CGPoint, geometry: CanvasGeometry) -> CGPoint {
        let display = geometry.displayRect
        let bounded = CGPoint(
            x: min(max(viewPoint.x, display.minX), display.maxX),
            y: min(max(viewPoint.y, display.minY), display.maxY)
        )
        return geometry.clampToSource(geometry.imagePoint(fromView: bounded))
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
        case .text, .crop: return nil
        }
    }

    private func trackTool(_ tool: AnnotationTool) {
        if tool == .crop, lastTool != .crop {
            toolBeforeCrop = lastTool
        }
        lastTool = tool
        refreshCursor(for: tool)
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
        Self.cursor(for: tool).set()
    }

    private func beginTextEditing(at imagePoint: CGPoint, geometry: CanvasGeometry) {
        let style = document.style
        let field = NSTextField(frame: .zero)
        field.font = AnnotationRenderer.font(for: style, scale: 1 / geometry.imageScale)
        field.textColor = style.color.nsColor
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = self

        let editing = TextEditing(
            field: field,
            origin: imagePoint,
            style: style,
            textInset: Self.textInset(of: field)
        )
        addSubview(field)
        fitEditor(editing)
        window?.makeFirstResponder(field)
        textEditing = editing
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
        let anchor = CGPoint(
            x: editing.origin.x + editing.textInset * geometry.imageScale,
            y: editing.origin.y
        )
        guard !string.isEmpty else { return anchor }
        let source = geometry.sourceRect
        let size = AnnotationRenderer.textSize(for: string, style: editing.style)
        // A string wider or taller than the visible image cannot be rescued by shifting: pin it
        // to the edge and let it clip — identically here and in the export, which is what the
        // editor width below enforces.
        return CGPoint(
            x: min(anchor.x, max(source.minX, source.maxX - size.width)),
            y: min(anchor.y, max(source.minY, source.maxY - size.height))
        )
    }

    /// The string as it will be drawn: trimmed, so the editor and the commit measure the same
    /// characters and cannot place them differently.
    private func editedString(of editing: TextEditing) -> String {
        let raw = editing.field.currentEditor()?.string ?? editing.field.stringValue
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Places and sizes the editor for the geometry and the text in force *now*. Called again
    /// from `layout()` and on every keystroke, because the editor is a preview of the committed
    /// annotation and a preview drawn at a stale scale, or running past the crop, is a lie.
    private func fitEditor(_ editing: TextEditing) {
        let geometry = self.geometry
        let font = AnnotationRenderer.font(for: editing.style, scale: 1 / geometry.imageScale)
        editing.field.font = font
        let glyph = geometry.viewPoint(fromImage: glyphOrigin(
            for: editedString(of: editing),
            editing: editing,
            geometry: geometry
        ))
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        // The editor ends exactly where the export ends, so a string too wide for the crop is
        // cut in the same place on screen as in the PNG. One inset, for the leading side only:
        // measured, a `.byClipping` cell runs its glyphs to the frame's trailing edge rather
        // than reserving padding there, so a second inset would paint 2 pt into the letterbox.
        // The floor keeps a caret's worth of field when the anchor is hard against the right
        // edge and nothing has been typed yet.
        let width = max(Self.minimumEditorWidth, geometry.displayRect.maxX - glyph.x + editing.textInset)
        editing.field.frame = CGRect(
            x: glyph.x - editing.textInset,
            y: glyph.y,
            width: width,
            height: height
        )
    }

    /// Measured, not assumed: `NSTextFieldCell` lays its glyphs out inset horizontally from the
    /// cell's leading edge by the field editor's line-fragment padding, and an empty cell's
    /// width is exactly that padding on each side. `drawingRect(forBounds:)` cannot supply it —
    /// on a borderless, non-background-drawing field it returns the bare bounds. Must be read
    /// while the field is still empty. The vertical inset is zero (the cell top-aligns its one
    /// line), which is why only x is compensated.
    private static func textInset(of field: NSTextField) -> CGFloat {
        guard let cell = field.cell else { return 0 }
        return cell.cellSize.width / 2
    }

    /// Internal so the window controller's delivery path can resolve a half-typed label before
    /// the document is handed to the delegate. A no-op when nothing is being edited.
    func commitTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        // Read before the teardown, and prefer the field editor: while an edit is live it is
        // the authoritative copy of what the user has typed.
        let typed = editing.field.currentEditor()?.string ?? editing.field.stringValue
        let string = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same placement the editor was using, recomputed against the geometry in force
        // now — so a resize or a crop mid-edit commits where the user was last shown the text,
        // and the extent-aware shift applies to the committed annotation too. Deriving it from
        // the shared function rather than reading the field's frame removes the round trip
        // through `textInset` entirely.
        let origin = glyphOrigin(for: string, editing: editing, geometry: geometry)
        endEditing(editing)
        guard !string.isEmpty else { return }
        document.append(Annotation(kind: .text(origin: origin, string: string), style: editing.style))
    }

    /// Discards a half-typed label. A no-op when nothing is being edited.
    func cancelTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        endEditing(editing)
    }

    private func endEditing(_ editing: TextEditing) {
        // Detach first: tearing the field down ends editing, which would otherwise re-enter.
        editing.field.delegate = nil
        editing.field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }
}

extension AnnotationCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTextEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape cancels the edit and stops there: it must not close the window.
            cancelTextEditing()
            return true
        default:
            return false
        }
    }

    /// Re-places the editor on every keystroke: once the string reaches the crop's edge it
    /// stops growing rightward and starts pushing itself left, the way text scrolls when the
    /// caret reaches the end of a field — except nothing is hidden, because the whole string
    /// moves rather than sliding out of a fixed box.
    func controlTextDidChange(_ obj: Notification) {
        guard let textEditing else { return }
        fitEditor(textEditing)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Any other way of losing focus — a toolbar click, say — commits what was typed.
        commitTextEditing()
    }
}
