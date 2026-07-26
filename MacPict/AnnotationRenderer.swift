import AppKit
import CoreGraphics
import Foundation

/// Draws annotations into a TOP-LEFT-origin, flipped graphics context.
///
/// The caller guarantees the CTM and `isFlipped`; the renderer never flips. That is what
/// makes the on-screen canvas and the exported PNG structurally identical instead of two
/// drawing routines somebody has to keep in sync (PLAN D-1). Two callers satisfy the
/// contract: `AnnotationCanvasView`, whose `isFlipped` is `true`, and `SnapshotExporter`,
/// which flips its bitmap context before wrapping it.
enum AnnotationRenderer {
    /// Arrow head length as a multiple of the stroke width.
    static let arrowHeadLengthFactor: CGFloat = 4.0
    /// Half-angle between the shaft and each barb.
    static let arrowHeadAngle: CGFloat = .pi / 7

    /// - Parameter scale: multiply image-pixel geometry by this to reach context units.
    ///   1.0 for the export bitmap; `1 / geometry.imageScale` for the canvas.
    static func draw(_ annotations: [Annotation], in context: NSGraphicsContext, scale: CGFloat) {
        for annotation in annotations {
            draw(annotation, in: context, scale: scale)
        }
    }

    static func draw(_ annotation: Annotation, in context: NSGraphicsContext, scale: CGFloat) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.saveGraphicsState()
        defer {
            context.restoreGraphicsState()
            NSGraphicsContext.current = previous
        }

        let style = annotation.style
        switch annotation.kind {
        case let .line(from, to):
            stroke(linePath(from: scaled(from, scale), to: scaled(to, scale)), style: style, scale: scale)
        case let .arrow(from, to):
            let start = scaled(from, scale)
            let end = scaled(to, scale)
            stroke(linePath(from: start, to: end), style: style, scale: scale)
            drawArrowHead(from: start, to: end, style: style, scale: scale)
        case let .box(rect):
            stroke(NSBezierPath(rect: scaled(rect, scale)), style: style, scale: scale)
        case let .ellipse(rect):
            stroke(NSBezierPath(ovalIn: scaled(rect, scale)), style: style, scale: scale)
        case let .text(origin, string):
            drawText(string, at: origin, style: style, maxWidth: nil, in: context, scale: scale)
        }
    }

    static func font(for style: AnnotationStyle, scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * scale, weight: .semibold)
    }

    /// Fill only, in `style.color`, with no stroke. An earlier version added a contrasting
    /// outline here; it was removed because the live `NSTextField` editor draws plain filled
    /// glyphs, so the outline appeared only once the text was committed and changed what the
    /// user had just composed. The editor is the preview, so the render must match it exactly.
    static func textAttributes(for style: AnnotationStyle, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: style, scale: scale),
            .foregroundColor: style.color.nsColor
        ]
    }

    /// Measured in image pixels, so it measures at `scale: 1.0`.
    static func textSize(for string: String, style: AnnotationStyle) -> CGSize {
        textSize(for: string, style: style, maxWidth: nil)
    }

    /// Size of `string` laid out with the given wrap width, in IMAGE PIXELS.
    /// `maxWidth` nil means no wrapping — explicit newlines still break lines.
    static func textSize(for string: String, style: AnnotationStyle, maxWidth: CGFloat?) -> CGSize {
        TextLayout(string: string, style: style, maxWidth: maxWidth).usedSize
    }

    /// Draws `string` with its top-left at `origin`, wrapped to `maxWidth` (image pixels,
    /// nil for none). Same flipped top-left-origin context contract as `draw`.
    ///
    /// Where the lines break is decided **once**, in image pixels, and each resulting line is
    /// then drawn at the scaled font size. Both halves of that are load-bearing:
    ///
    /// - Breaking at image-pixel metrics makes the canvas preview and the export break lines
    ///   identically. Glyph advances are not exactly linear in point size, so a layout
    ///   recomputed at a scaled font disagrees with itself: "The quick brown fox jumps over
    ///   the lazy dog" is four lines at 36 pt / 200 px and five at 18 pt / 100 px. The agent
    ///   would then receive text the user never saw.
    /// - Drawing each line at the scaled font keeps glyph placement identical to the live
    ///   editor, which lays out at that size. Committed text must not shift when the user
    ///   presses Return.
    static func drawText(
        _ string: String,
        at origin: CGPoint,
        style: AnnotationStyle,
        maxWidth: CGFloat?,
        in context: NSGraphicsContext,
        scale: CGFloat
    ) {
        guard !string.isEmpty, scale.isFinite, scale > 0 else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.saveGraphicsState()
        defer {
            context.restoreGraphicsState()
            NSGraphicsContext.current = previous
        }

        let attributes = textAttributes(for: style, scale: scale)
        let source = string as NSString
        for line in TextLayout(string: string, style: style, maxWidth: maxWidth).lineFragments() {
            // The fragment's character range carries its terminating newline, which would
            // otherwise be drawn as a second, empty line.
            var text = source.substring(with: line.range)
            while let last = text.last, last.isNewline { text.removeLast() }
            guard !text.isEmpty else { continue }
            NSAttributedString(string: text, attributes: attributes).draw(
                at: CGPoint(x: (origin.x + line.origin.x) * scale, y: (origin.y + line.origin.y) * scale)
            )
        }
    }

    /// The two barb tips of the head drawn at `to`, in context units. `nil` when the arrow
    /// has no direction — a zero-length drag must not turn into NaN coordinates.
    static func arrowHead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> (left: CGPoint, right: CGPoint)? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length > 0 else { return nil }

        let angle = atan2(dy, dx)
        let headLength = arrowHeadLengthFactor * lineWidth
        return (
            left: CGPoint(
                x: to.x - headLength * cos(angle - arrowHeadAngle),
                y: to.y - headLength * sin(angle - arrowHeadAngle)
            ),
            right: CGPoint(
                x: to.x - headLength * cos(angle + arrowHeadAngle),
                y: to.y - headLength * sin(angle + arrowHeadAngle)
            )
        )
    }

    private static func drawArrowHead(from: CGPoint, to: CGPoint, style: AnnotationStyle, scale: CGFloat) {
        guard let head = arrowHead(from: from, to: to, lineWidth: style.lineWidth * scale) else { return }
        let path = NSBezierPath()
        path.move(to: to)
        path.line(to: head.left)
        path.line(to: head.right)
        path.close()
        style.color.nsColor.setFill()
        path.fill()
    }

    private static func linePath(from: CGPoint, to: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        return path
    }

    private static func stroke(_ path: NSBezierPath, style: AnnotationStyle, scale: CGFloat) {
        path.lineWidth = style.lineWidth * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        style.color.nsColor.setStroke()
        path.stroke()
    }

    private static func scaled(_ point: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private static func scaled(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}

/// One TextKit 1 layout, always in image-pixel metrics.
///
/// `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` are the objects an `NSTextView`
/// drives natively, so an editor built on one breaks lines exactly where this does; hand-rolled
/// measurement could only approximate that, and the editor is meant to be a live preview of
/// this renderer. A word too long to fit is broken between characters by TextKit rather than
/// overflowing, so painted text never exceeds `maxWidth`.
private struct TextLayout {
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer

    init(string: String, style: AnnotationStyle, maxWidth: CGFloat?) {
        storage = NSTextStorage(
            string: string,
            attributes: AnnotationRenderer.textAttributes(for: style, scale: 1.0)
        )
        // A non-positive or non-finite wrap width means "do not wrap" rather than "collapse
        // to nothing", which is the only reading that cannot silently swallow a user's text.
        let width: CGFloat
        if let maxWidth, maxWidth.isFinite, maxWidth > 0 {
            width = maxWidth
        } else {
            width = .greatestFiniteMagnitude
        }
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        // NSTextView defaults this to 5 points, which would silently narrow the wrap width:
        // an editor previewing this layout has to zero it too.
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    /// Image pixels. Line spacing comes from the font's own metrics, so it scales with
    /// `style.fontSize` without a separate absolute value to keep in step.
    var usedSize: CGSize { manager.usedRect(for: container).size }

    /// One entry per rendered line, in the order they stack downward: the characters on that
    /// line and the top-left of its line box relative to the text block's origin, in image
    /// pixels. This is the single place line breaking is decided.
    func lineFragments() -> [(range: NSRange, origin: CGPoint)] {
        var fragments: [(range: NSRange, origin: CGPoint)] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphRange, _ in
            fragments.append((
                range: manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil),
                origin: rect.origin
            ))
        }
        return fragments
    }
}
