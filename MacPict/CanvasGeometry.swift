import CoreGraphics
import Foundation

/// Maps between the canvas view's space (points, TOP-LEFT origin because the canvas
/// NSView is flipped) and the image's pixel space (also TOP-LEFT origin). `sourceRect` is
/// the visible sub-rect of the image — the crop — and it is aspect-fit inside the view, so
/// the mapping is a pure scale-and-translate: there is no y-inversion anywhere, and nothing
/// else in the app may add one. Image coordinates are always FULL-image, never crop-relative.
struct CanvasGeometry: Equatable, Sendable {
    let imageSize: CGSize
    let sourceRect: CGRect
    let viewSize: CGSize

    /// Uncropped: the source rect is the whole image.
    init(imageSize: CGSize, viewSize: CGSize) {
        self.init(imageSize: imageSize, sourceRect: CGRect(origin: .zero, size: imageSize), viewSize: viewSize)
    }

    init(imageSize: CGSize, sourceRect: CGRect, viewSize: CGSize) {
        self.imageSize = imageSize
        self.sourceRect = sourceRect
        self.viewSize = viewSize
    }

    /// Aspect-fit rect of `sourceRect` in view points, `.zero` when anything is unusable — a
    /// canvas is routinely asked for its geometry before it has been laid out.
    var displayRect: CGRect {
        guard let fitScale else { return .zero }
        let width = sourceRect.width * fitScale
        let height = sourceRect.height * fitScale
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Source pixels per view point; 1 when anything is unusable.
    var imageScale: CGFloat {
        guard let fitScale else { return 1 }
        return 1 / fitScale
    }

    func imagePoint(fromView point: CGPoint) -> CGPoint {
        let rect = displayRect
        let origin = sourceOrigin
        let scale = imageScale
        return CGPoint(
            x: origin.x + (point.x - rect.minX) * scale,
            y: origin.y + (point.y - rect.minY) * scale
        )
    }

    func viewPoint(fromImage point: CGPoint) -> CGPoint {
        let rect = displayRect
        let origin = sourceOrigin
        let scale = imageScale
        return CGPoint(
            x: rect.minX + (point.x - origin.x) / scale,
            y: rect.minY + (point.y - origin.y) / scale
        )
    }

    func imageRect(fromView rect: CGRect) -> CGRect {
        let origin = imagePoint(fromView: rect.origin)
        let scale = imageScale
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    func viewRect(fromImage rect: CGRect) -> CGRect {
        let origin = viewPoint(fromImage: rect.origin)
        let scale = imageScale
        return CGRect(x: origin.x, y: origin.y, width: rect.width / scale, height: rect.height / scale)
    }

    /// Clamps a point into `sourceRect`, the region currently visible and the only one that
    /// survives cropping into the exported image. Still full-image coordinates: this changes
    /// the bounds, not the space. A degenerate source has no meaningful bounds to clamp into,
    /// so the point passes through rather than being forced against an inverted range.
    func clampToSource(_ point: CGPoint) -> CGPoint {
        guard isSourceUsable else { return point }
        return CGPoint(
            x: min(max(point.x, sourceRect.minX), sourceRect.maxX),
            y: min(max(point.y, sourceRect.minY), sourceRect.maxY)
        )
    }

    /// View points per source pixel, or nil when any input is degenerate.
    private var fitScale: CGFloat? {
        guard Self.isUsable(imageSize), Self.isUsable(viewSize), isSourceUsable else { return nil }
        return min(viewSize.width / sourceRect.width, viewSize.height / sourceRect.height)
    }

    /// Falls back to `.zero` while degenerate, so a bad source rect can never leak a NaN or an
    /// infinity into a mouse coordinate.
    private var sourceOrigin: CGPoint {
        fitScale == nil ? .zero : sourceRect.origin
    }

    private var isSourceUsable: Bool {
        Self.isUsable(sourceRect.size)
            && sourceRect.origin.x.isFinite && sourceRect.origin.y.isFinite
            && sourceRect.minX >= 0 && sourceRect.minY >= 0
            && sourceRect.maxX <= imageSize.width && sourceRect.maxY <= imageSize.height
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
