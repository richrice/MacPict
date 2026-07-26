import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MacPict

@MainActor
final class SnapshotExporterTests: XCTestCase {
    private let imageWidth = 200
    private let imageHeight = 100

    /// Pixels encode their own top-left-origin coordinates: red == x, green == y.
    private func makeImage() throws -> CGImage {
        try XCTUnwrap(RenderTestSupport.coordinateImage(width: imageWidth, height: imageHeight))
    }

    private let wideWidth = 400
    private let wideHeight = 200

    /// Same coordinate encoding, but wide enough for the fractional-crop numbers. The
    /// channels wrap at 256, so expectations go through `assertWideCoordinatePixel`.
    private func makeWideImage() throws -> CGImage {
        try XCTUnwrap(RenderTestSupport.rawImage(width: wideWidth, height: wideHeight) { x, y in
            (UInt8(x % 256), UInt8(y % 256), 128)
        })
    }

    private func decodePNG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// True when the pixel still carries the untouched coordinate pattern for the given
    /// full-image coordinates, i.e. no annotation was painted over it.
    private func assertCoordinatePixel(
        _ buffer: RenderPixelBuffer,
        at point: (x: Int, y: Int),
        equals expected: (x: Int, y: Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A regression that crops too small must name the test that caught it, not sample
        // past the end of the buffer and take the whole test host down with it.
        guard point.x < buffer.width, point.y < buffer.height else {
            XCTFail("sample \(point) outside \(buffer.width)x\(buffer.height)", file: file, line: line)
            return
        }
        let sample = buffer.pixel(x: point.x, y: point.y, file: file, line: line)
        XCTAssertEqual(Int(sample.r), expected.x, accuracy: 1, "red encodes x", file: file, line: line)
        XCTAssertEqual(Int(sample.g), expected.y, accuracy: 1, "green encodes y", file: file, line: line)
    }

    private func assertWideCoordinatePixel(
        _ buffer: RenderPixelBuffer,
        at point: (x: Int, y: Int),
        equals expected: (x: Int, y: Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard point.x < buffer.width, point.y < buffer.height else {
            XCTFail("sample \(point) outside \(buffer.width)x\(buffer.height)", file: file, line: line)
            return
        }
        let sample = buffer.pixel(x: point.x, y: point.y, file: file, line: line)
        XCTAssertEqual(Int(sample.r), expected.x % 256, accuracy: 1, "red encodes x", file: file, line: line)
        XCTAssertEqual(Int(sample.g), expected.y % 256, accuracy: 1, "green encodes y", file: file, line: line)
    }

    /// End to end: a stored `wrapWidth` has to survive the annotation switch, the flatten and
    /// the PNG encode, and come out breaking lines exactly where a direct `drawText` call
    /// with the same width does. A white base image is used so ink reads the same way the
    /// renderer tests read it.
    func testExportedPNGBreaksLinesLikeADirectDrawTextCall() throws {
        let sample = "The quick brown fox jumps over the lazy dog"
        let style = AnnotationStyle(color: .black, size: .medium)
        let origin = CGPoint(x: 10, y: 10)
        let maxWidth: CGFloat = 200
        let size = (width: 400, height: 400)

        let white = try XCTUnwrap(RenderTestSupport.rawImage(width: size.width, height: size.height) { _, _ in (255, 255, 255) })
        let annotation = Annotation(kind: .text(origin: origin, string: sample, wrapWidth: maxWidth), style: style)
        let exported = try XCTUnwrap(RenderPixelBuffer(image: try decodePNG(
            try SnapshotExporter.png(image: white, annotations: [annotation])
        )))
        let direct = try XCTUnwrap(RenderTestSupport.flippedRender(width: size.width, height: size.height) { context in
            AnnotationRenderer.drawText(sample, at: origin, style: style, maxWidth: maxWidth, in: context, scale: 1.0)
        })

        let lineHeight = AnnotationRenderer.textSize(for: "X", style: style, maxWidth: nil).height
        let lineCount = Int((AnnotationRenderer.textSize(for: sample, style: style, maxWidth: maxWidth).height / lineHeight).rounded())
        XCTAssertGreaterThan(lineCount, 2, "the sample must wrap for this to prove anything")
        for index in 0..<lineCount {
            let rows = Int(origin.y + CGFloat(index) * lineHeight)..<Int(origin.y + CGFloat(index + 1) * lineHeight)
            let exportedLine = try XCTUnwrap(exported.inkColumns(inRows: rows), "line \(index) missing from the PNG")
            XCTAssertEqual(exportedLine, direct.inkColumns(inRows: rows), "line \(index) broke differently in the export")
        }
        XCTAssertNil(
            exported.inkColumns(inRows: Int(origin.y + CGFloat(lineCount) * lineHeight + 2)..<size.height),
            "an extra line in the export means the wrap width was lost"
        )
    }

    func testFlattenPreservesPixelDimensionsExactly() throws {
        let image = try makeImage()
        let box = Annotation(kind: .box(CGRect(x: 10, y: 10, width: 50, height: 30)), style: .default)

        let flattened = try SnapshotExporter.flatten(image: image, annotations: [box])
        XCTAssertEqual(flattened.width, imageWidth)
        XCTAssertEqual(flattened.height, imageHeight)
    }

    func testPNGDecodesBackToTheInputDimensions() throws {
        let image = try makeImage()
        let data = try SnapshotExporter.png(image: image, annotations: [])
        let decoded = try decodePNG(data)

        XCTAssertEqual(decoded.width, imageWidth)
        XCTAssertEqual(decoded.height, imageHeight)
    }

    func testEmptyAnnotationsLeaveTheBaseImagePixelsIntact() throws {
        let image = try makeImage()
        let flattened = try SnapshotExporter.flatten(image: image, annotations: [])
        let original = try XCTUnwrap(RenderPixelBuffer(image: image))
        let exported = try XCTUnwrap(RenderPixelBuffer(image: flattened))

        XCTAssertEqual(exported.width, original.width)
        XCTAssertEqual(exported.height, original.height)
        var mismatches = 0
        for y in 0..<original.height {
            for x in 0..<original.width {
                let lhs = original.pixel(x: x, y: y)
                let rhs = exported.pixel(x: x, y: y)
                if abs(Int(lhs.r) - Int(rhs.r)) > 1 || abs(Int(lhs.g) - Int(rhs.g)) > 1
                    || abs(Int(lhs.b) - Int(rhs.b)) > 1 || lhs.a != rhs.a {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    /// The end-to-end version of the renderer's placement test: through flatten, through
    /// PNG encoding, and back. A y-flip anywhere on that path fails here.
    func testAnnotationLandsAtTheSamePixelCoordinatesInTheExportedPNG() throws {
        let image = try makeImage()
        let box = Annotation(kind: .box(CGRect(x: 20, y: 15, width: 60, height: 30)), style: .default)
        let data = try SnapshotExporter.png(image: image, annotations: [box])
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: try decodePNG(data)))

        // Red annotation ink over a pattern whose red channel equals x: at x == 20 the
        // untouched pixel is nearly black-red, the annotation is saturated red.
        XCTAssertTrue(isAnnotationInk(buffer, x: 20, y: 15), "top-left corner of the box")
        // The same corner mirrored about the horizontal centre line.
        XCTAssertFalse(isAnnotationInk(buffer, x: 20, y: imageHeight - 15), "mirrored corner")
    }

    func testCropUsesTopLeftOriginAndKeepsTheCorrectRegion() throws {
        let image = try makeImage()
        let cropRect = CGRect(x: 30, y: 10, width: 40, height: 20)
        let cropped = try SnapshotExporter.flatten(image: image, annotations: [], cropRect: cropRect)
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: cropped))

        XCTAssertEqual(buffer.width, 40)
        XCTAssertEqual(buffer.height, 20)
        // Every pixel must still report its ORIGINAL top-left coordinates. Had
        // cropping(to:) measured from the bottom-left, green would read
        // imageHeight - y - height + j instead.
        assertCoordinatePixel(buffer, at: (x: 0, y: 0), equals: (x: 30, y: 10))
        assertCoordinatePixel(buffer, at: (x: 39, y: 19), equals: (x: 69, y: 29))
        assertCoordinatePixel(buffer, at: (x: 10, y: 5), equals: (x: 40, y: 15))
    }

    func testCroppedOutputDimensionsEqualTheCropRectSize() throws {
        let image = try makeImage()
        let data = try SnapshotExporter.png(
            image: image,
            annotations: [],
            cropRect: CGRect(x: 12, y: 7, width: 55, height: 33)
        )
        let decoded = try decodePNG(data)

        XCTAssertEqual(decoded.width, 55)
        XCTAssertEqual(decoded.height, 33)
    }

    /// A resizable canvas at a non-integral scale produces fractional crop rects nearly
    /// every time, so this — not the tidy integral case above — is the realistic input.
    /// Alignment is `AnnotationDocument`'s single policy: floor the origin, ceil the max
    /// edges. x 30.03…330.33 therefore becomes 30…331, i.e. 301 px, and the exporter must
    /// deliver exactly that.
    func testFractionalCropRectIsAlignedByTheDocumentPolicy() throws {
        let image = try makeWideImage()
        let cropRect = CGRect(x: 30.03, y: 10.4, width: 300.30, height: 40.2)
        let aligned = try XCTUnwrap(AnnotationDocument.pixelAlignedRect(
            cropRect,
            imageSize: CGSize(width: wideWidth, height: wideHeight)
        ))
        XCTAssertEqual(aligned, CGRect(x: 30, y: 10, width: 301, height: 41))

        let decoded = try decodePNG(try SnapshotExporter.png(image: image, annotations: [], cropRect: cropRect))
        XCTAssertEqual(decoded.width, Int(aligned.width))
        XCTAssertEqual(decoded.height, Int(aligned.height))

        // Dimensions alone would still pass if the exporter had grabbed the right-sized
        // block from the wrong offset, so pin the actual source pixels too.
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: decoded))
        assertWideCoordinatePixel(buffer, at: (x: 0, y: 0), equals: (x: 30, y: 10))
        assertWideCoordinatePixel(buffer, at: (x: 300, y: 40), equals: (x: 330, y: 50))
    }

    /// If any rounding of crop geometry were left in `SnapshotExporter`, it would apply to
    /// the fractional rect and not to the already-aligned one, and the two exports would
    /// differ.
    func testFractionalAndPreAlignedCropRectsProduceIdenticalBytes() throws {
        let image = try makeWideImage()
        let box = Annotation(kind: .box(CGRect(x: 100, y: 20, width: 120, height: 60)), style: .default)

        let fromFractional = try SnapshotExporter.png(
            image: image,
            annotations: [box],
            cropRect: CGRect(x: 30.03, y: 10.4, width: 300.30, height: 40.2)
        )
        let fromAligned = try SnapshotExporter.png(
            image: image,
            annotations: [box],
            cropRect: CGRect(x: 30, y: 10, width: 301, height: 41)
        )

        XCTAssertEqual(fromFractional, fromAligned)
    }

    func testCropRectPartlyOutsideTheImageIsClampedRatherThanRejected() throws {
        let image = try makeImage()
        let cropRect = CGRect(x: 180, y: 80, width: 60, height: 60)
        let cropped = try SnapshotExporter.flatten(image: image, annotations: [], cropRect: cropRect)
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: cropped))

        XCTAssertEqual(buffer.width, 20)
        XCTAssertEqual(buffer.height, 20)
        assertCoordinatePixel(buffer, at: (x: 0, y: 0), equals: (x: 180, y: 80))
        assertCoordinatePixel(buffer, at: (x: 19, y: 19), equals: (x: 199, y: 99))
    }

    func testCropRectOutsideTheImageThrows() throws {
        let image = try makeImage()

        XCTAssertThrowsError(try SnapshotExporter.flatten(
            image: image,
            annotations: [],
            cropRect: CGRect(x: 400, y: 400, width: 50, height: 50)
        )) { error in
            XCTAssertEqual(error as? SnapshotExporterError, .cropOutOfBounds)
        }
        XCTAssertThrowsError(try SnapshotExporter.png(
            image: image,
            annotations: [],
            cropRect: CGRect(x: -100, y: 0, width: 50, height: 50)
        )) { error in
            XCTAssertEqual(error as? SnapshotExporterError, .cropOutOfBounds)
        }
    }

    func testAnnotationOutsideTheCropDoesNotAppear() throws {
        let image = try makeImage()
        let box = Annotation(kind: .box(CGRect(x: 5, y: 5, width: 40, height: 30)), style: .default)
        let cropRect = CGRect(x: 120, y: 50, width: 60, height: 40)
        let cropped = try SnapshotExporter.flatten(image: image, annotations: [box], cropRect: cropRect)
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: cropped))

        var painted = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where isAnnotationInk(buffer, x: x, y: y) {
                painted += 1
            }
        }
        XCTAssertEqual(painted, 0)
        assertCoordinatePixel(buffer, at: (x: 0, y: 0), equals: (x: 120, y: 50))
    }

    func testAnnotationStraddlingTheCropEdgeIsClippedNotDropped() throws {
        let image = try makeImage()
        // Spans x 80…140, so its right edge sits inside a crop that starts at x == 100.
        let box = Annotation(kind: .box(CGRect(x: 80, y: 30, width: 60, height: 40)), style: .default)
        let cropRect = CGRect(x: 100, y: 20, width: 60, height: 60)
        let cropped = try SnapshotExporter.flatten(image: image, annotations: [box], cropRect: cropRect)
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: cropped))

        XCTAssertEqual(buffer.width, 60)
        XCTAssertEqual(buffer.height, 60)
        // The box's right edge (full-image x == 140, y == 30…70) lands at crop x == 40.
        XCTAssertTrue(isAnnotationInk(buffer, x: 40, y: 30), "the surviving right edge")
        // The part of the box left of the crop is gone, and so is everything beyond its edge.
        XCTAssertFalse(isAnnotationInk(buffer, x: 55, y: 30), "outside the box")
        assertCoordinatePixel(buffer, at: (x: 55, y: 5), equals: (x: 155, y: 25))
    }

    /// The untouched pattern has a blue channel of exactly 128 in every pixel, and the
    /// default annotation colour is red (blue 51), so the blue channel alone says whether a
    /// pixel was painted over.
    private func isAnnotationInk(
        _ buffer: RenderPixelBuffer,
        x: Int,
        y: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        abs(Int(buffer.pixel(x: x, y: y, file: file, line: line).b) - 128) > 20
    }
}
