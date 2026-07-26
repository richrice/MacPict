import AppKit
import CoreGraphics
import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    // crop is appended last so the pre-existing 1…5 mapping is untouched.
    case arrow, box, ellipse, line, text, crop

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .text: "Text"
        case .crop: "Crop"
        }
    }

    // Must stay aligned with the CaseIterable order above: the annotation window binds
    // the number keys 1…6 positionally, and AnnotationModelTests locks that alignment.
    var keyEquivalent: String {
        switch self {
        case .arrow: "1"
        case .box: "2"
        case .ellipse: "3"
        case .line: "4"
        case .text: "5"
        case .crop: "6"
        }
    }
}

enum AnnotationColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, magenta, white, black

    var id: String { rawValue }

    // Explicit sRGB rather than the dynamic catalog colours: these are baked into an
    // exported PNG and must not shift with appearance or with the display's profile.
    var nsColor: NSColor {
        switch self {
        case .red: NSColor(srgbRed: 1.0, green: 0.20, blue: 0.20, alpha: 1.0)
        case .orange: NSColor(srgbRed: 1.0, green: 0.58, blue: 0.0, alpha: 1.0)
        case .yellow: NSColor(srgbRed: 1.0, green: 0.87, blue: 0.0, alpha: 1.0)
        case .green: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
        case .blue: NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        case .magenta: NSColor(srgbRed: 1.0, green: 0.18, blue: 0.80, alpha: 1.0)
        case .white: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .black: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        }
    }
}

enum AnnotationSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    /// Image pixels, not view points — annotations are stored in the image raster.
    var lineWidth: CGFloat {
        switch self {
        case .small: 4
        case .medium: 8
        case .large: 14
        }
    }

    /// Image pixels, matching `lineWidth`.
    var fontSize: CGFloat {
        switch self {
        case .small: 24
        case .medium: 36
        case .large: 56
        }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor
    var size: AnnotationSize

    var lineWidth: CGFloat { size.lineWidth }
    var fontSize: CGFloat { size.fontSize }

    static let `default` = AnnotationStyle(color: .red, size: .medium)
}

/// All geometry is in IMAGE PIXELS with a TOP-LEFT origin (y grows downward).
struct Annotation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
        case ellipse(CGRect)
        case text(origin: CGPoint, string: String)
    }

    let id: UUID
    var kind: Kind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }
}

@MainActor
final class AnnotationDocument: ObservableObject {
    /// Smallest accepted crop, in image pixels, on either side.
    nonisolated static let minimumCropSide: CGFloat = 16

    let image: CGImage
    let imageSize: CGSize

    @Published private(set) var annotations: [Annotation] = []
    /// Visible sub-rect of `image`, in full-image pixels, top-left origin.
    @Published private(set) var cropRect: CGRect
    // Crop first: the capture is tightened to what matters, then annotated.
    @Published var tool: AnnotationTool = .crop
    @Published var style: AnnotationStyle = .default

    // Snapshot undo: each entry carries the whole annotation array *and* the crop rect, so a
    // single undo always restores a consistent pair. Annotations are small value types, and
    // this makes a multi-annotation clear() a single undoable step for free.
    private struct Snapshot {
        var annotations: [Annotation]
        var cropRect: CGRect
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(image: CGImage) {
        self.image = image
        let size = CGSize(width: image.width, height: image.height)
        imageSize = size
        cropRect = CGRect(origin: .zero, size: size)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { annotations.isEmpty }
    var isCropped: Bool { cropRect != fullImageRect }
    /// Size actually delivered to the agent.
    var outputSize: CGSize { cropRect.size }

    func append(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        apply(next)
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations = []
    }

    /// Annotations are never rewritten: they stay in full-image coordinates, which is what
    /// makes a nested crop and an undone crop both work without any fix-up (§11.2).
    func crop(to rect: CGRect) {
        guard let canonical = Self.canonicalCropRect(rect, imageSize: imageSize) else { return }
        // Outward pixel alignment makes two nearly-identical drags collapse to the same
        // integral rect, so a re-crop that changes nothing must not cost the user a ⌘Z.
        guard canonical != cropRect else { return }
        pushUndo()
        cropRect = canonical
    }

    func resetCrop() {
        guard isCropped else { return }
        pushUndo()
        cropRect = fullImageRect
    }

    func cycleSize(forward: Bool) {
        let sizes = AnnotationSize.allCases
        guard let index = sizes.firstIndex(of: style.size) else { return }
        let offset = forward ? 1 : sizes.count - 1
        style.size = sizes[(index + offset) % sizes.count]
    }

    private var fullImageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    private var currentSnapshot: Snapshot { Snapshot(annotations: annotations, cropRect: cropRect) }

    private func pushUndo() {
        undoStack.append(currentSnapshot)
        redoStack.removeAll()
    }

    private func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
    }
}

// The single rounding policy for crops. A drag on a resizable canvas produces fractional
// image coordinates, so the rect is aligned to whole pixels here, once, and every consumer
// — preview, exporter, and the W × H readout — then agrees by construction.
extension AnnotationDocument {
    /// Rounds `rect` outward to whole image pixels and clamps it to `imageSize`.
    /// Returns nil when the result is empty or does not intersect the image.
    nonisolated static func pixelAlignedRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }

        let standardized = rect.standardized
        guard standardized.minX.isFinite, standardized.minY.isFinite,
              standardized.width.isFinite, standardized.height.isFinite,
              standardized.width > 0, standardized.height > 0 else { return nil }

        // Outward, not nearest: a crop must never lose a pixel row the user dragged over.
        let minX = max(standardized.minX.rounded(.down), 0)
        let minY = max(standardized.minY.rounded(.down), 0)
        let maxX = min(standardized.maxX.rounded(.up), imageSize.width)
        let maxY = min(standardized.maxY.rounded(.up), imageSize.height)
        guard maxX > minX, maxY > minY else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `pixelAlignedRect` plus the `minimumCropSide` policy.
    /// Returns nil when the crop should be rejected.
    nonisolated static func canonicalCropRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        // Alignment first: the accept/reject decision must be made on the rect that will
        // actually be used, not on the raw fractional one.
        guard let aligned = pixelAlignedRect(rect, imageSize: imageSize) else { return nil }
        guard aligned.width >= minimumCropSide, aligned.height >= minimumCropSide else { return nil }
        return aligned
    }
}
