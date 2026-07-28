import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SnapshotExporterError: Error, Equatable, LocalizedError {
    case bitmapContextCreationFailed
    case imageCreationFailed
    case pngEncodingFailed
    case cropOutOfBounds

    var errorDescription: String? {
        switch self {
        case .bitmapContextCreationFailed:
            "MacPict could not create an image buffer for the snapshot."
        case .imageCreationFailed:
            "MacPict could not create the annotated image."
        case .pngEncodingFailed:
            "MacPict could not encode the annotated image as PNG."
        case .cropOutOfBounds:
            "The selected crop does not overlap the captured image."
        }
    }
}

enum SnapshotExporter {
    /// Composites `annotations` over `image` at the image's native pixel size.
    static func flatten(image: CGImage, annotations: [Annotation]) throws -> CGImage {
        try flatten(image: image, annotations: annotations, cropRect: nil)
    }

    static func png(image: CGImage, annotations: [Annotation]) throws -> Data {
        try png(image: image, annotations: annotations, cropRect: nil)
    }

    /// - Parameter cropRect: visible sub-rect in image pixels, top-left origin. `nil` is
    ///   the full image. A rect that overlaps the image only partly is clamped to it.
    /// - Throws: `.cropOutOfBounds` when `cropRect` does not intersect the image.
    static func flatten(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> CGImage {
        let pixelSize = CGSize(width: image.width, height: image.height)
        // Annotation colours are sRGB (see AnnotationColor), so the export is too.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SnapshotExporterError.bitmapContextCreationFailed
        }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw SnapshotExporterError.bitmapContextCreationFailed
        }

        // The base image belongs in CoreGraphics' native bottom-left space, where it lands
        // the right way up. Only afterwards is the context flipped into the top-left space
        // the annotation geometry — and AnnotationRenderer's contract — is expressed in.
        context.saveGState()
        context.draw(image, in: CGRect(origin: .zero, size: pixelSize))
        context.restoreGState()

        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(
            annotations,
            in: NSGraphicsContext(cgContext: context, flipped: true),
            scale: 1.0
        )

        guard let flattened = context.makeImage() else {
            throw SnapshotExporterError.imageCreationFailed
        }
        guard let cropRect else { return flattened }

        // Crop the finished image rather than drawing into a crop-sized context: a
        // translated CTM would put coordinate maths on the one path where a mistake is
        // invisible until it reaches the agent (PLAN §11.4).
        //
        // The rounding policy belongs to AnnotationDocument and lives there alone. On the
        // real path this call changes nothing, because `AnnotationDocument.crop(to:)` has
        // already pixel-aligned its `cropRect` — the point is that the exporter must not
        // hold a *second* opinion about where a fractional drag lands, not that it is
        // repairing bad input.
        guard let aligned = AnnotationDocument.pixelAlignedRect(cropRect, imageSize: pixelSize) else {
            throw SnapshotExporterError.cropOutOfBounds
        }
        guard let cropped = flattened.cropping(to: aligned) else {
            throw SnapshotExporterError.imageCreationFailed
        }
        return cropped
    }

    static func png(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> Data {
        let flattened = try flatten(image: image, annotations: annotations, cropRect: cropRect)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SnapshotExporterError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, flattened, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotExporterError.pngEncodingFailed
        }
        return data as Data
    }
}
