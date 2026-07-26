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

    /// Outline thickness for text. AppKit reads `.strokeWidth` as a percentage of the font
    /// size, so the outline scales with `scale` for free — see `textAttributes`.
    private static let textOutlinePercent: CGFloat = 8.0

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
            guard !string.isEmpty else { return }
            let attributed = NSAttributedString(string: string, attributes: textAttributes(for: style, scale: scale))
            attributed.draw(at: scaled(origin, scale))
        }
    }

    static func font(for style: AnnotationStyle, scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * scale, weight: .semibold)
    }

    /// A screenshot can be any colour underneath the text, so the glyphs carry a
    /// contrasting outline: a negative `.strokeWidth` means fill *and* stroke, and AppKit
    /// expresses it as a percentage of the font size. That makes the outline scale exactly
    /// with `scale`, so the canvas preview and the export agree by construction — a shadow
    /// would need its blur radius scaled by hand and would smear at preview scales.
    static func textAttributes(for style: AnnotationStyle, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: style, scale: scale),
            .foregroundColor: style.color.nsColor,
            .strokeColor: outlineColor(for: style.color),
            .strokeWidth: -textOutlinePercent
        ]
    }

    /// Measured in image pixels, so it measures at `scale: 1.0`.
    static func textSize(for string: String, style: AnnotationStyle) -> CGSize {
        NSAttributedString(string: string, attributes: textAttributes(for: style, scale: 1.0)).size()
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

    /// `AnnotationColor.nsColor` is always built in sRGB, so the components read directly.
    private static func outlineColor(for color: AnnotationColor) -> NSColor {
        let nsColor = color.nsColor
        let luminance = 0.2126 * nsColor.redComponent
            + 0.7152 * nsColor.greenComponent
            + 0.0722 * nsColor.blueComponent
        return luminance > 0.5 ? .black : .white
    }

    private static func scaled(_ point: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private static func scaled(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}
