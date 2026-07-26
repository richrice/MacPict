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
        /// Top-left of the text box in image pixels, captured when editing began.
        let origin: CGPoint
        let style: AnnotationStyle
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
                MainActor.assumeIsolated { self?.needsDisplay = true }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.setFill()
        bounds.fill()

        let geometry = self.geometry
        let displayRect = geometry.displayRect
        guard !displayRect.isEmpty else { return }

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

        if let drag, drag.isCrop {
            drawCropOverlay(for: drag, displayRect: displayRect, geometry: geometry)
        }
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

    /// Clamps into the *visible* image first, so nothing can be drawn into the letterbox or a
    /// crop be dragged back out beyond what is on screen.
    private func imagePoint(for viewPoint: CGPoint, geometry: CanvasGeometry) -> CGPoint {
        let display = geometry.displayRect
        let bounded = CGPoint(
            x: min(max(viewPoint.x, display.minX), display.maxX),
            y: min(max(viewPoint.y, display.minY), display.maxY)
        )
        return geometry.clampToImage(geometry.imagePoint(fromView: bounded))
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
    }

    private func beginTextEditing(at imagePoint: CGPoint, geometry: CanvasGeometry) {
        let style = document.style
        let font = AnnotationRenderer.font(for: style, scale: 1 / geometry.imageScale)
        let field = NSTextField(frame: .zero)
        field.font = font
        field.textColor = style.color.nsColor
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = self

        let origin = geometry.viewPoint(fromImage: imagePoint)
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        field.frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: max(80, bounds.maxX - origin.x - 4),
            height: height
        )
        addSubview(field)
        window?.makeFirstResponder(field)
        textEditing = TextEditing(field: field, origin: imagePoint, style: style)
    }

    /// Internal so the window controller's delivery path can resolve a half-typed label before
    /// the document is handed to the delegate. A no-op when nothing is being edited.
    func commitTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        // Read before the teardown, and prefer the field editor: while an edit is live it is
        // the authoritative copy of what the user has typed.
        let typed = editing.field.currentEditor()?.string ?? editing.field.stringValue
        endEditing(editing)
        let string = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return }
        document.append(Annotation(kind: .text(origin: editing.origin, string: string), style: editing.style))
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

    func controlTextDidEndEditing(_ obj: Notification) {
        // Any other way of losing focus — a toolbar click, say — commits what was typed.
        commitTextEditing()
    }
}
