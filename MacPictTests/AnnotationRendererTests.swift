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

    /// Horizontal extent of the ink inside a row window, or nil when that window is blank.
    /// Slicing by row window addresses a text line by *where the line box is*, which needs no
    /// guess about how big a blank gap separates two lines.
    func inkColumns(inRows rows: Range<Int>) -> ClosedRange<Int>? {
        var minX = width, maxX = -1
        for y in rows where y >= 0 && y < height {
            for x in 0..<width where isInk(x: x, y: y) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= 0 else { return nil }
        return minX...maxX
    }

    /// Tight bounding box of all ink, or nil when the buffer is blank.
    func inkBounds() -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where isInk(x: x, y: y) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// One entry per band of consecutive inked rows, with that band's horizontal ink extent.
    /// For text this is one entry per rendered line, which is how the tests compare *where
    /// lines broke* rather than merely how much ink appeared.
    ///
    /// Note that a band is a run of inked rows, which is one text line only when the line has
    /// something taller than the x-height in it: "jumps over" paints the dot of the "j", a
    /// blank run, and then the rest. Tests that need *typographic* lines slice by row window
    /// with `inkColumns(inRows:)` instead of counting bands.
    func inkLineBands() -> [(rows: ClosedRange<Int>, columns: ClosedRange<Int>)] {
        var bands: [(rows: ClosedRange<Int>, columns: ClosedRange<Int>)] = []
        var start: Int?
        var minX = width, maxX = -1
        for y in 0...height {
            var rowMinX = width, rowMaxX = -1
            if y < height {
                for x in 0..<width where isInk(x: x, y: y) {
                    rowMinX = min(rowMinX, x)
                    rowMaxX = max(rowMaxX, x)
                }
            }
            if rowMaxX >= 0 {
                if start == nil { start = y }
                minX = min(minX, rowMinX)
                maxX = max(maxX, rowMaxX)
            } else if let first = start {
                bands.append((rows: first...(y - 1), columns: minX...maxX))
                start = nil
                minX = width
                maxX = -1
            }
        }
        return bands
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

    private static let wrapSample = "The quick brown fox jumps over the lazy dog"

    func testExplicitNewlineRendersOnSeparateLines() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let origin = CGPoint(x: 20, y: 20)
        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 300, height: 200) { context in
            AnnotationRenderer.drawText("HH\nHH", at: origin, style: style, maxWidth: nil, in: context, scale: 1.0)
        })

        let bands = buffer.inkLineBands()
        XCTAssertEqual(bands.count, 2, "an embedded newline must break the line")
        // The gap between the bands is what "none between them" means: consecutive bands are
        // separated by at least one completely blank row by construction of inkLineBands.
        let gap = CGRect(
            x: 0,
            y: CGFloat(bands[0].rows.upperBound + 1),
            width: CGFloat(buffer.width),
            height: CGFloat(bands[1].rows.lowerBound - bands[0].rows.upperBound - 1)
        )
        XCTAssertGreaterThan(gap.height, 0, "the two lines must not touch")
        XCTAssertEqual(buffer.inkCount(in: gap), 0)
        // Both lines are the same string, so they must occupy the same columns.
        XCTAssertEqual(bands[0].columns.lowerBound, bands[1].columns.lowerBound, accuracy: 1)
        XCTAssertEqual(bands[0].columns.upperBound, bands[1].columns.upperBound, accuracy: 1)

        // And the measurement has to know about the newline too, or a caller sizing an
        // editor or a crop from it would cut the second line off.
        let size = AnnotationRenderer.textSize(for: "HH\nHH", style: style, maxWidth: nil)
        XCTAssertEqual(size.height, AnnotationRenderer.textSize(for: "HH", style: style, maxWidth: nil).height * 2, accuracy: 0.5)
    }

    func testTextWrapsAtMaxWidth() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let maxWidth: CGFloat = 200
        let origin = CGPoint(x: 10, y: 10)

        let wrapped = try XCTUnwrap(RenderTestSupport.flippedRender(width: 400, height: 400) { context in
            AnnotationRenderer.drawText(Self.wrapSample, at: origin, style: style, maxWidth: maxWidth, in: context, scale: 1.0)
        })
        let unwrapped = try XCTUnwrap(RenderTestSupport.flippedRender(width: 900, height: 400) { context in
            AnnotationRenderer.drawText(Self.wrapSample, at: origin, style: style, maxWidth: nil, in: context, scale: 1.0)
        })

        let wrappedInk = try XCTUnwrap(wrapped.inkBounds())
        let unwrappedInk = try XCTUnwrap(unwrapped.inkBounds())

        XCTAssertGreaterThan(wrappedInk.height, unwrappedInk.height, "wrapping must add lines")
        XCTAssertLessThanOrEqual(wrappedInk.maxX, origin.x + maxWidth, "no ink may cross the wrap width")
        XCTAssertGreaterThan(wrapped.inkLineBands().count, 1)
        XCTAssertEqual(unwrapped.inkLineBands().count, 1, "no wrap width means one line")
    }

    func testTextSizeMatchesWhatDrawTextPaints() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let maxWidth: CGFloat = 200
        let origin = CGPoint(x: 20, y: 20)
        let measured = AnnotationRenderer.textSize(for: Self.wrapSample, style: style, maxWidth: maxWidth)

        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 400, height: 400) { context in
            AnnotationRenderer.drawText(Self.wrapSample, at: origin, style: style, maxWidth: maxWidth, in: context, scale: 1.0)
        })
        let ink = try XCTUnwrap(buffer.inkBounds())
        let lineHeight = AnnotationRenderer.textSize(for: "X", style: style, maxWidth: nil).height

        // The failure mode that matters is a measured height that does not account for every
        // painted line — that is what puts text outside a crop sized from `textSize`. So tie
        // the two together directly: the measured height must be a whole number of lines,
        // every one of those line boxes must contain ink, and the box after the last must not.
        let lineCount = measured.height / lineHeight
        XCTAssertEqual(lineCount, lineCount.rounded(), accuracy: 0.01, "measured height is a whole number of lines")
        for index in 0..<Int(lineCount.rounded()) {
            let top = Int(origin.y + CGFloat(index) * lineHeight)
            XCTAssertNotNil(
                buffer.inkColumns(inRows: top..<Int(origin.y + CGFloat(index + 1) * lineHeight)),
                "line \(index) of the measured box painted nothing"
            )
        }
        let afterLast = Int(origin.y + measured.height)
        XCTAssertNil(
            buffer.inkColumns(inRows: (afterLast + 1)..<(afterLast + Int(lineHeight))),
            "ink below the measured box means the measurement is short"
        )

        // Vertical containment is exact — the ascent and descent bound the glyphs.
        XCTAssertGreaterThanOrEqual(ink.minY, origin.y - 1)
        XCTAssertLessThanOrEqual(ink.maxY, origin.y + measured.height + 1)
        // Horizontally, `textSize` reports the *typographic* box, and a glyph may paint
        // slightly outside its advance width: the sample's "jumps" begins a line and the "j"
        // has a negative left side bearing, which puts ~2 px of ink left of the box at 36 pt.
        // That is correct typography, so the assertion allows a side bearing of up to a tenth
        // of the font size — and no more, which still fails a genuinely mismeasured box.
        let sideBearing = style.fontSize * 0.1
        XCTAssertGreaterThanOrEqual(ink.minX, origin.x - sideBearing)
        XCTAssertLessThanOrEqual(ink.maxX, origin.x + measured.width + sideBearing)
        // And it must not be wildly generous either, or the box would be useless for layout.
        XCTAssertGreaterThan(ink.width, measured.width * 0.8)
        XCTAssertGreaterThan(ink.height, measured.height * 0.7)
    }

    /// The WYSIWYG guarantee: the canvas preview draws at `1 / imageScale` and the export at
    /// 1.0, so if those two laid text out independently they could break lines differently and
    /// the agent would receive something the user never saw.
    func testWrappedTextBreaksAtTheSameWordBoundariesAtEveryScale() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let maxWidth: CGFloat = 200
        let origin = CGPoint(x: 10, y: 10)

        let lineHeight = AnnotationRenderer.textSize(for: "X", style: style, maxWidth: nil).height
        let lineCount = Int((AnnotationRenderer.textSize(for: Self.wrapSample, style: style, maxWidth: maxWidth).height / lineHeight).rounded())
        XCTAssertGreaterThan(lineCount, 2, "the sample must actually wrap for this to prove anything")

        func render(scale: CGFloat) throws -> RenderPixelBuffer {
            try XCTUnwrap(RenderTestSupport.flippedRender(width: 400, height: 400) { context in
                AnnotationRenderer.drawText(
                    Self.wrapSample,
                    at: origin,
                    style: style,
                    maxWidth: maxWidth,
                    in: context,
                    scale: scale
                )
            })
        }

        let full = try render(scale: 1.0)
        let half = try render(scale: 0.5)

        // Every line's ink must occupy the same place once the half-scale render is doubled —
        // including the ragged right edge, which is where a different word boundary shows up
        // first. Lines are addressed by their line box, so a wrap that moved a word to the
        // next line changes that line's right edge by a whole word.
        //
        // The right edge gets a wider tolerance than the left because glyph advances are not
        // exactly linear in point size: a line drawn at 18 pt is a percent or two narrower
        // than half of its 36 pt self. The narrowest word in the sample is about 60 px wide
        // here, so 10 px cannot absorb a line that gained or lost a word — the thing under
        // test — while it does absorb that sub-percent metric drift.
        let wordBoundaryTolerance = 10.0
        for index in 0..<lineCount {
            let top = origin.y + CGFloat(index) * lineHeight
            let bottom = origin.y + CGFloat(index + 1) * lineHeight
            let fullLine = try XCTUnwrap(full.inkColumns(inRows: Int(top)..<Int(bottom)), "line \(index) at scale 1.0")
            let halfLine = try XCTUnwrap(half.inkColumns(inRows: Int(top / 2)..<Int(bottom / 2)), "line \(index) at scale 0.5")

            XCTAssertEqual(Double(halfLine.lowerBound) * 2, Double(fullLine.lowerBound), accuracy: 3, "line \(index) left")
            XCTAssertEqual(
                Double(halfLine.upperBound) * 2,
                Double(fullLine.upperBound),
                accuracy: wordBoundaryTolerance,
                "line \(index) right edge"
            )
        }
        // Nothing may spill past the last line box at either scale — that would be an extra
        // line at one scale and not the other.
        XCTAssertNil(full.inkColumns(inRows: Int(origin.y + CGFloat(lineCount) * lineHeight + 2)..<400))
        XCTAssertNil(half.inkColumns(inRows: Int((origin.y + CGFloat(lineCount) * lineHeight) / 2 + 2)..<400))
    }

    /// TextKit breaks a word that cannot fit between characters rather than overflowing, so
    /// painted text never crosses `maxWidth` however long a single word is.
    func testWordLongerThanMaxWidthIsBrokenBetweenCharacters() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let maxWidth: CGFloat = 100
        let origin = CGPoint(x: 10, y: 10)
        let word = "Supercalifragilisticexpialidocious"

        let measured = AnnotationRenderer.textSize(for: word, style: style, maxWidth: maxWidth)
        XCTAssertLessThanOrEqual(measured.width, maxWidth)
        XCTAssertGreaterThan(measured.height, AnnotationRenderer.textSize(for: word, style: style, maxWidth: nil).height)

        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 300, height: 400) { context in
            AnnotationRenderer.drawText(word, at: origin, style: style, maxWidth: maxWidth, in: context, scale: 1.0)
        })
        let ink = try XCTUnwrap(buffer.inkBounds())
        XCTAssertLessThanOrEqual(ink.maxX, origin.x + maxWidth, "the word is broken, never overflowed")
        XCTAssertGreaterThan(buffer.inkLineBands().count, 1)
    }

    func testDegenerateTextInputsAreSafe() throws {
        let style = AnnotationStyle(color: .black, size: .medium)
        let origin = CGPoint(x: 10, y: 10)

        XCTAssertEqual(AnnotationRenderer.textSize(for: "", style: style, maxWidth: 100), CGSize(width: 0, height: 14))
        // A non-positive or non-finite wrap width must mean "do not wrap", not "collapse".
        for width in [CGFloat(0), -50, .infinity, .nan] {
            XCTAssertEqual(
                AnnotationRenderer.textSize(for: "Hello", style: style, maxWidth: width),
                AnnotationRenderer.textSize(for: "Hello", style: style, maxWidth: nil),
                "maxWidth \(width)"
            )
        }

        let buffer = try XCTUnwrap(RenderTestSupport.flippedRender(width: 200, height: 100) { context in
            AnnotationRenderer.drawText("", at: origin, style: style, maxWidth: 100, in: context, scale: 1.0)
            AnnotationRenderer.drawText("x", at: origin, style: style, maxWidth: 0, in: context, scale: 1.0)
            AnnotationRenderer.drawText("x", at: origin, style: style, maxWidth: .nan, in: context, scale: 1.0)
        })
        XCTAssertGreaterThan(buffer.inkCount(in: CGRect(x: 0, y: 0, width: 200, height: 100)), 0, "the non-empty draws still paint")
    }
}
