import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import MacPict

/// A top-left-origin pixel view of a `CGImage`: `pixel(x:y:)` with `y == 0` is the top row,
/// which is the same convention the annotation geometry uses. Shared with
/// `SnapshotExporterTests` — both suites have to assert on real pixels, and duplicating the
/// read-back machinery would let the two copies drift.
struct RenderPixelBuffer {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: CGImage) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        width = image.width
        height = image.height
        let count = image.width * image.height * 4
        bytes = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
    }

    /// Guarded here rather than at each call site: a crop-geometry regression that returns a
    /// *smaller* image than expected would otherwise trap inside the array subscript, killing
    /// the test host and replacing a named failure with a truncated summary. The sentinel is
    /// unreachable in a passing run because `XCTFail` has already failed the test.
    func pixel(x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else {
            XCTFail("sample (\(x), \(y)) outside \(width)x\(height)", file: file, line: line)
            return (0, 0, 0, 0)
        }
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// Anything visibly darker than the white test background.
    func isInk(x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let sample = pixel(x: x, y: y, file: file, line: line)
        return sample.r < 200 || sample.g < 200 || sample.b < 200
    }

    func inkCount(in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) where y >= 0 && y < height {
            for x in Int(rect.minX)..<Int(rect.maxX) where x >= 0 && x < width {
                if isInk(x: x, y: y) { count += 1 }
            }
        }
        return count
    }
}

enum RenderTestSupport {
    /// Builds a context that satisfies `AnnotationRenderer`'s contract exactly the way
    /// `SnapshotExporter` does — white background, CTM flipped to a top-left origin,
    /// `isFlipped == true` — then reads the result back.
    static func flippedRender(width: Int, height: Int, body: (NSGraphicsContext) -> Void) -> RenderPixelBuffer? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        body(NSGraphicsContext(cgContext: context, flipped: true))
        guard let image = context.makeImage() else { return nil }
        return RenderPixelBuffer(image: image)
    }

    /// Raw bytes, first row first — the documented `CGImage` layout, which
    /// `testTopRowOfRawBytesReadsBackAsTheTopRow` pins down.
    static func rawImage(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes.append(contentsOf: [r, g, b, 255])
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Every pixel encodes its own top-left-origin coordinates: red == x, green == y. Any
    /// crop or flip mistake shows up as a wrong coordinate rather than as a plausible image.
    static func coordinateImage(width: Int, height: Int) -> CGImage? {
        rawImage(width: width, height: height) { x, y in (UInt8(x), UInt8(y), 128) }
    }
}

@MainActor
final class AnnotationRendererTests: XCTestCase {
    private func annotation(_ kind: Annotation.Kind, style: AnnotationStyle = .default) -> Annotation {
        Annotation(kind: kind, style: style)
    }

    /// Anchors every other pixel assertion in this suite and in `SnapshotExporterTests`: it
    /// proves that byte row 0 of a `CGImage` is the row that `RenderPixelBuffer` reports at
    /// `y == 0`, so "top-left origin" means the same thing to the tests as it does to the
    /// renderer.
    func testTopRowOfRawBytesReadsBackAsTheTopRow() throws {
        let image = try XCTUnwrap(RenderTestSupport.rawImage(width: 4, height: 2) { _, y in
            y == 0 ? (255, 0, 0) : (0, 0, 255)
        })
        let buffer = try XCTUnwrap(RenderPixelBuffer(image: image))

        XCTAssertEqual(buffer.pixel(x: 0, y: 0).r, 255)
        XCTAssertEqual(buffer.pixel(x: 0, y: 0).b, 0)
        XCTAssertEqual(buffer.pixel(x: 3, y: 1).r, 0)
        XCTAssertEqual(buffer.pixel(x: 3, y: 1).b, 255)
    }

    func testBoxLandsAtTheSameTopLeftPixelCoordinates() throws {
        let box = annotation(.box(CGRect(x: 20, y: 15, width: 60, height: 30)))
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 200, height: 120) { context in
            AnnotationRenderer.draw([box], in: context, scale: 1.0)
        })

        XCTAssertGreaterThan(buffer.inkCount(in: CGRect(x: 12, y: 7, width: 16, height: 16)), 0, "top-left corner")
        // The same corner mirrored about the horizontal centre line: ink here means a y-flip.
        XCTAssertEqual(buffer.inkCount(in: CGRect(x: 12, y: 97, width: 16, height: 16)), 0, "mirrored corner")
    }

    func testTextRendersRightSideUp() throws {
        let style = AnnotationStyle(color: .black, size: .large)
        let scale: CGFloat = 4
        let origin = CGPoint(x: 10, y: 10)
        // A full stop is ink at the baseline and nowhere else, so an upside-down draw moves
        // every inked pixel from the bottom half of the text box into the top half.
        let size = AnnotationRenderer.textSize(for: ".", style: style)
        let text = annotation(.text(origin: origin, string: "."), style: style)
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 400, height: 400) { context in
            AnnotationRenderer.draw([text], in: context, scale: scale)
        })

        let box = CGRect(
            x: origin.x * scale,
            y: origin.y * scale,
            width: size.width * scale,
            height: size.height * scale
        )
        let topHalf = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height / 2)
        let bottomHalf = CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2)

        XCTAssertGreaterThan(buffer.inkCount(in: bottomHalf), 0, "baseline ink")
        XCTAssertEqual(buffer.inkCount(in: topHalf), 0, "ink above the baseline means the text is upside down")
    }

    func testArrowHeadIsDrawnAtTheToEnd() throws {
        let arrow = annotation(.arrow(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50)))
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 200, height: 100) { context in
            AnnotationRenderer.draw([arrow], in: context, scale: 1.0)
        })

        let nearFrom = buffer.inkCount(in: CGRect(x: 20, y: 20, width: 40, height: 60))
        let nearTo = buffer.inkCount(in: CGRect(x: 140, y: 20, width: 40, height: 60))
        XCTAssertGreaterThan(nearFrom, 0, "the shaft reaches both ends")
        XCTAssertGreaterThan(nearTo, Int(Double(nearFrom) * 1.5), "the head belongs at the to end")
    }

    func testZeroLengthArrowHasNoHeadAndNoNaN() throws {
        XCTAssertNil(AnnotationRenderer.arrowHead(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 40, y: 40), lineWidth: 8))

        let head = try XCTUnwrap(AnnotationRenderer.arrowHead(
            from: CGPoint(x: 40, y: 40),
            to: CGPoint(x: 100, y: 40),
            lineWidth: 8
        ))
        XCTAssertTrue(head.left.x.isFinite && head.left.y.isFinite)
        XCTAssertTrue(head.right.x.isFinite && head.right.y.isFinite)

        // The degenerate drag itself must still render (a dot from the round cap) and must
        // leave the rest of the canvas untouched rather than scattering NaN geometry.
        let point = CGPoint(x: 40, y: 40)
        let degenerate = [
            annotation(.arrow(from: point, to: point)),
            annotation(.line(from: point, to: point))
        ]
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 100, height: 100) { context in
            AnnotationRenderer.draw(degenerate, in: context, scale: 1.0)
        })
        XCTAssertEqual(buffer.inkCount(in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       buffer.inkCount(in: CGRect(x: 30, y: 30, width: 20, height: 20)))
    }

    func testScaleHalvesTheGeometry() throws {
        let box = annotation(.box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let full = try XCTUnwrap(RenderTestSupport.flippedRender(width: 200, height: 200) { context in
            AnnotationRenderer.draw([box], in: context, scale: 1.0)
        })
        let half = try XCTUnwrap(RenderTestSupport.flippedRender(width: 200, height: 200) { context in
            AnnotationRenderer.draw([box], in: context, scale: 0.5)
        })

        // Full scale: corners at (40,40) and (120,80). Half scale: (20,20) and (60,40).
        XCTAssertGreaterThan(full.inkCount(in: CGRect(x: 34, y: 34, width: 12, height: 12)), 0)
        XCTAssertGreaterThan(full.inkCount(in: CGRect(x: 114, y: 74, width: 12, height: 12)), 0)
        XCTAssertGreaterThan(half.inkCount(in: CGRect(x: 14, y: 14, width: 12, height: 12)), 0)
        XCTAssertGreaterThan(half.inkCount(in: CGRect(x: 54, y: 34, width: 12, height: 12)), 0)
        XCTAssertEqual(half.inkCount(in: CGRect(x: 70, y: 0, width: 130, height: 200)), 0, "nothing beyond half width")
    }

    func testFontAndTextSizeScale() {
        let style = AnnotationStyle(color: .red, size: .medium)
        XCTAssertEqual(AnnotationRenderer.font(for: style, scale: 1.0).pointSize, style.fontSize, accuracy: 1e-9)
        XCTAssertEqual(AnnotationRenderer.font(for: style, scale: 0.5).pointSize, style.fontSize / 2, accuracy: 1e-9)

        // textSize is documented as image pixels, i.e. measured at scale 1.
        let measured = AnnotationRenderer.textSize(for: "Hello", style: style)
        let attributes = AnnotationRenderer.textAttributes(for: style, scale: 1.0)
        XCTAssertEqual(measured, NSAttributedString(string: "Hello", attributes: attributes).size())
        XCTAssertGreaterThan(measured.width, 0)
        XCTAssertGreaterThanOrEqual(measured.height, style.fontSize)
    }

    /// The committed annotation has to look like what the live `NSTextField` editor showed
    /// while the user was typing, and the editor draws plain filled glyphs. So the render is
    /// fill-only: no stroke attribute, no outline ink.
    func testTextRendersFillOnlyWithNoOutline() throws {
        for color in [AnnotationColor.yellow, .blue] {
            let attributes = AnnotationRenderer.textAttributes(for: AnnotationStyle(color: color, size: .medium), scale: 1.0)
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, color.nsColor)
            XCTAssertNil(attributes[.strokeWidth], "a stroke would appear only on commit")
            XCTAssertNil(attributes[.strokeColor], "a stroke would appear only on commit")
        }

        // Pixel proof, not just an attribute check: yellow glyphs on white must leave no dark
        // ink anywhere. The removed outline was black for a light colour like yellow, so it
        // would darken every glyph edge in this render.
        let style = AnnotationStyle(color: .yellow, size: .large)
        let text = annotation(.text(origin: CGPoint(x: 10, y: 10), string: "Hgy"), style: style)
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 300, height: 160) { context in
            AnnotationRenderer.draw([text], in: context, scale: 1.0)
        })

        var darkPixels = 0
        var fillPixels = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let sample = buffer.pixel(x: x, y: y)
                if sample.r < 100, sample.g < 100, sample.b < 100 { darkPixels += 1 }
                if sample.r > 200, sample.g > 200, sample.b < 100 { fillPixels += 1 }
            }
        }
        XCTAssertGreaterThan(fillPixels, 0, "the glyphs are filled in style.color")
        XCTAssertEqual(darkPixels, 0, "dark pixels mean the glyphs carry a contrasting outline")
    }
}
