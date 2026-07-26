import AppKit
import CoreGraphics
import XCTest
@testable import MacPict

@MainActor
final class AnnotationModelTests: XCTestCase {
    private func makeImage(width: Int = 64, height: Int = 32) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeDocument(width: Int = 64, height: Int = 32) throws -> AnnotationDocument {
        AnnotationDocument(image: try makeImage(width: width, height: height))
    }

    private func makeCroppableDocument() throws -> AnnotationDocument {
        try makeDocument(width: 200, height: 100)
    }

    private func box(_ offset: CGFloat) -> Annotation {
        Annotation(kind: .box(CGRect(x: offset, y: offset, width: 10, height: 10)), style: .default)
    }

    func testDocumentStartsEmptyWithImagePixelSize() throws {
        let document = AnnotationDocument(image: try makeImage(width: 128, height: 96))
        XCTAssertEqual(document.imageSize, CGSize(width: 128, height: 96))
        XCTAssertEqual(document.annotations, [])
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)
        // Crop is the initial tool: tighten the capture first, then annotate.
        XCTAssertEqual(document.tool, .crop)
        XCTAssertEqual(document.style, .default)
    }

    func testAppendClearsTheRedoStack() throws {
        let document = try makeDocument()
        let first = box(1)
        let second = box(2)
        let third = box(3)

        document.append(first)
        document.append(second)
        document.undo()
        XCTAssertEqual(document.annotations, [first])
        XCTAssertTrue(document.canRedo)

        document.append(third)
        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.annotations, [first, third])

        document.redo()
        XCTAssertEqual(document.annotations, [first, third])
    }

    func testUndoAndRedoRoundTripToAnIdenticalArray() throws {
        let document = try makeDocument()
        let annotations = [box(1), box(2), box(3)]
        for annotation in annotations {
            document.append(annotation)
        }
        XCTAssertEqual(document.annotations, annotations)

        document.undo()
        document.undo()
        document.undo()
        XCTAssertEqual(document.annotations, [])

        document.redo()
        document.redo()
        document.redo()
        XCTAssertEqual(document.annotations, annotations)
        XCTAssertEqual(document.annotations.map(\.id), annotations.map(\.id))
    }

    func testClearIsASingleUndoStepThatRestoresEveryAnnotation() throws {
        let document = try makeDocument()
        let annotations = [box(1), box(2), box(3)]
        for annotation in annotations {
            document.append(annotation)
        }

        document.clear()
        XCTAssertEqual(document.annotations, [])
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.undo()
        XCTAssertEqual(document.annotations, annotations)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.annotations, [])
    }

    func testUndoAndRedoFlagsAtTheStackBoundaries() throws {
        let document = try makeDocument()
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.append(box(1))
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.undo()
        XCTAssertFalse(document.canUndo)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)
    }

    func testUndoAtTheBottomAndRedoAtTheTopAreNoOps() throws {
        let document = try makeDocument()
        document.undo()
        document.undo()
        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.redo()
        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canRedo)

        let annotation = box(1)
        document.append(annotation)
        document.redo()
        document.redo()
        XCTAssertEqual(document.annotations, [annotation])
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.undo()
        document.undo()
        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canUndo)
        XCTAssertTrue(document.canRedo)
    }

    func testClearOnAnEmptyDocumentPushesNothing() throws {
        let document = try makeDocument()
        document.clear()
        XCTAssertFalse(document.canUndo)
        XCTAssertEqual(document.annotations, [])

        // A second clear with nothing left to clear must not push a second step either.
        let annotation = box(1)
        document.append(annotation)
        document.clear()
        document.clear()
        XCTAssertEqual(document.annotations, [])

        document.undo()
        XCTAssertEqual(document.annotations, [annotation], "one undo steps back over the clear")
        document.undo()
        XCTAssertEqual(document.annotations, [])
        XCTAssertFalse(document.canUndo)
    }

    func testInitialCropIsTheFullImage() throws {
        let document = try makeCroppableDocument()
        XCTAssertEqual(document.cropRect, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse(document.isCropped)
        XCTAssertEqual(document.outputSize, CGSize(width: 200, height: 100))
        XCTAssertFalse(document.canUndo)
        XCTAssertEqual(AnnotationDocument.minimumCropSide, 16)
    }

    func testCropClampsToTheImageBounds() throws {
        let topLeft = try makeCroppableDocument()
        topLeft.crop(to: CGRect(x: -20, y: -10, width: 100, height: 60))
        XCTAssertEqual(topLeft.cropRect, CGRect(x: 0, y: 0, width: 80, height: 50))
        XCTAssertTrue(topLeft.isCropped)
        XCTAssertEqual(topLeft.outputSize, CGSize(width: 80, height: 50))

        let bottomRight = try makeCroppableDocument()
        bottomRight.crop(to: CGRect(x: 150, y: 60, width: 100, height: 80))
        XCTAssertEqual(bottomRight.cropRect, CGRect(x: 150, y: 60, width: 50, height: 40))
        XCTAssertEqual(bottomRight.outputSize, CGSize(width: 50, height: 40))
    }

    func testCropRejectsSubMinimumRectsWithoutMutatingStateOrPushingUndo() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)

        document.crop(to: CGRect(x: 10, y: 10, width: 15, height: 40))
        XCTAssertEqual(document.cropRect, full, "narrow rect")
        document.crop(to: CGRect(x: 10, y: 10, width: 40, height: 15))
        XCTAssertEqual(document.cropRect, full, "short rect")
        document.crop(to: CGRect(x: 195, y: 0, width: 40, height: 40))
        XCTAssertEqual(document.cropRect, full, "rect that clamps down to sub-minimum")
        document.crop(to: CGRect(x: 400, y: 400, width: 50, height: 50))
        XCTAssertEqual(document.cropRect, full, "rect entirely outside the image")
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.isCropped)

        // A rejected crop must not disturb the redo stack either.
        document.append(box(1))
        document.undo()
        XCTAssertTrue(document.canRedo)
        document.crop(to: CGRect(x: 10, y: 10, width: 15, height: 15))
        XCTAssertTrue(document.canRedo)
        XCTAssertEqual(document.cropRect, full)

        document.crop(to: CGRect(x: 10, y: 10, width: AnnotationDocument.minimumCropSide, height: AnnotationDocument.minimumCropSide))
        XCTAssertEqual(document.cropRect, CGRect(x: 10, y: 10, width: 16, height: 16), "exactly minimum is accepted")
    }

    func testCropNormalisesABackwardsDrag() throws {
        let document = try makeCroppableDocument()
        document.crop(to: CGRect(x: 150, y: 80, width: -100, height: -50))
        XCTAssertEqual(document.cropRect, CGRect(x: 50, y: 30, width: 100, height: 50))
    }

    func testCropIsASingleUndoStepRestoringThePreviousCropRect() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cropped = CGRect(x: 20, y: 10, width: 100, height: 60)

        document.crop(to: cropped)
        XCTAssertEqual(document.cropRect, cropped)
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.undo()
        XCTAssertEqual(document.cropRect, full)
        XCTAssertFalse(document.isCropped)
        XCTAssertFalse(document.canUndo)

        document.redo()
        XCTAssertEqual(document.cropRect, cropped)
    }

    func testCroppingLeavesExistingAnnotationsIdentical() throws {
        let document = try makeCroppableDocument()
        let annotations = [box(1), box(2)]
        for annotation in annotations {
            document.append(annotation)
        }

        document.crop(to: CGRect(x: 40, y: 20, width: 80, height: 60))
        XCTAssertEqual(document.annotations, annotations, "crop must never rewrite annotation geometry")
        XCTAssertEqual(document.annotations.map(\.id), annotations.map(\.id))

        document.undo()
        XCTAssertEqual(document.annotations, annotations)
    }

    func testSuccessiveCropsUndoOneAtATimeInOrder() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)
        let first = CGRect(x: 0, y: 0, width: 120, height: 80)
        // Nested crops are expressed in full-image coordinates, so no special-casing.
        let second = CGRect(x: 10, y: 10, width: 60, height: 40)

        document.crop(to: first)
        document.crop(to: second)
        XCTAssertEqual(document.cropRect, second)

        document.undo()
        XCTAssertEqual(document.cropRect, first)
        document.undo()
        XCTAssertEqual(document.cropRect, full)
        XCTAssertFalse(document.canUndo)

        document.redo()
        XCTAssertEqual(document.cropRect, first)
        document.redo()
        XCTAssertEqual(document.cropRect, second)
        XCTAssertFalse(document.canRedo)
    }

    func testResetCropRestoresTheFullImageAndIsANoOpWhenUncropped() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cropped = CGRect(x: 20, y: 10, width: 100, height: 60)

        document.resetCrop()
        XCTAssertFalse(document.canUndo, "reset on an uncropped document must not push an undo step")
        XCTAssertEqual(document.cropRect, full)

        document.crop(to: cropped)
        document.resetCrop()
        XCTAssertEqual(document.cropRect, full)
        XCTAssertFalse(document.isCropped)

        document.resetCrop()
        document.undo()
        XCTAssertEqual(document.cropRect, cropped, "one undo steps back to the crop, not past it")
        document.undo()
        XCTAssertEqual(document.cropRect, full)
        XCTAssertFalse(document.canUndo)
    }

    func testUndoRestoresAnnotationsAndCropAsAConsistentPair() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cropped = CGRect(x: 20, y: 10, width: 100, height: 60)
        let first = box(1)
        let second = box(2)

        document.append(first)
        document.crop(to: cropped)
        document.append(second)
        XCTAssertEqual(document.annotations, [first, second])
        XCTAssertEqual(document.cropRect, cropped)

        document.undo()
        XCTAssertEqual(document.annotations, [first])
        XCTAssertEqual(document.cropRect, cropped)

        document.undo()
        XCTAssertEqual(document.annotations, [first])
        XCTAssertEqual(document.cropRect, full)

        document.undo()
        XCTAssertEqual(document.annotations, [])
        XCTAssertEqual(document.cropRect, full)

        document.redo()
        document.redo()
        XCTAssertEqual(document.annotations, [first])
        XCTAssertEqual(document.cropRect, cropped)
    }

    func testClearDoesNotChangeTheCrop() throws {
        let document = try makeCroppableDocument()
        let cropped = CGRect(x: 20, y: 10, width: 100, height: 60)
        document.append(box(1))
        document.crop(to: cropped)
        document.clear()
        XCTAssertEqual(document.annotations, [])
        XCTAssertEqual(document.cropRect, cropped)

        document.undo()
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.cropRect, cropped)
    }

    private func assertIntegral(
        _ rect: CGRect,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.minX, rect.minX.rounded(), "minX \(message)", file: file, line: line)
        XCTAssertEqual(rect.minY, rect.minY.rounded(), "minY \(message)", file: file, line: line)
        XCTAssertEqual(rect.width, rect.width.rounded(), "width \(message)", file: file, line: line)
        XCTAssertEqual(rect.height, rect.height.rounded(), "height \(message)", file: file, line: line)
    }

    func testInitialCropRectIsPixelAligned() throws {
        let document = try makeCroppableDocument()
        assertIntegral(document.cropRect)
        XCTAssertEqual(
            AnnotationDocument.pixelAlignedRect(document.cropRect, imageSize: document.imageSize),
            document.cropRect,
            "the full-image rect is already canonical"
        )
    }

    func testFractionalCropIsAlignedToWholePixels() throws {
        let document = try makeDocument(width: 400, height: 200)
        // The review's numbers: a drag on a non-integrally scaled canvas.
        let requested = CGRect(x: 30.03, y: 20.5, width: 300.30, height: 100.25)
        document.crop(to: requested)

        XCTAssertEqual(document.cropRect, CGRect(x: 30, y: 20, width: 301, height: 101))
        assertIntegral(document.cropRect)
        XCTAssertEqual(document.outputSize, CGSize(width: 301, height: 101))
        XCTAssertTrue(document.cropRect.contains(requested), "rounding must be outward, never inward")
    }

    func testFractionalCropRoundsOutwardOnEverySide() throws {
        let document = try makeDocument(width: 400, height: 200)
        let requested = CGRect(x: 100.9, y: 50.9, width: 100.2, height: 60.2)
        document.crop(to: requested)

        // floor(100.9) = 100, ceil(201.1) = 202, floor(50.9) = 50, ceil(111.1) = 112.
        XCTAssertEqual(document.cropRect, CGRect(x: 100, y: 50, width: 102, height: 62))
        XCTAssertTrue(document.cropRect.contains(requested))
        assertIntegral(document.cropRect)
    }

    func testFractionalCropThatAlignsPastTheEdgeIsClampedAndStaysIntegral() throws {
        let document = try makeCroppableDocument()
        document.crop(to: CGRect(x: 150.4, y: 60.7, width: 100.2, height: 80.9))

        XCTAssertEqual(document.cropRect, CGRect(x: 150, y: 60, width: 50, height: 40))
        assertIntegral(document.cropRect)
        XCTAssertTrue(document.cropRect.maxX <= document.imageSize.width)
        XCTAssertTrue(document.cropRect.maxY <= document.imageSize.height)
    }

    func testFractionalCropBelowTheMinimumAfterAlignmentIsRejected() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)

        // ceil(24.3) - floor(10.2) = 25 - 10 = 15, one short of the minimum.
        document.crop(to: CGRect(x: 10.2, y: 10.0, width: 14.1, height: 40.0))
        XCTAssertEqual(document.cropRect, full)
        XCTAssertFalse(document.isCropped)
        XCTAssertFalse(document.canUndo)
    }

    func testFractionalCropThatRoundsOutwardUpToTheMinimumIsAccepted() throws {
        let document = try makeCroppableDocument()
        // Raw size 15.2 is below minimumCropSide, but it aligns outward to exactly 16.
        // Checking the minimum before alignment would wrongly reject this.
        document.crop(to: CGRect(x: 10.5, y: 10.5, width: 15.2, height: 15.2))

        XCTAssertEqual(document.cropRect, CGRect(x: 10, y: 10, width: 16, height: 16))
        XCTAssertTrue(document.isCropped)
        XCTAssertTrue(document.canUndo)
    }

    func testRecroppingToTheSameAlignedRectPushesNoUndoStep() throws {
        let document = try makeCroppableDocument()
        let full = CGRect(x: 0, y: 0, width: 200, height: 100)

        document.crop(to: CGRect(x: 10.2, y: 10.2, width: 40.1, height: 40.1))
        let aligned = CGRect(x: 10, y: 10, width: 41, height: 41)
        XCTAssertEqual(document.cropRect, aligned)

        // A different fractional drag that aligns to the very same integral rect.
        document.crop(to: CGRect(x: 10.7, y: 10.4, width: 39.6, height: 39.8))
        XCTAssertEqual(document.cropRect, aligned, "no visible change")

        document.undo()
        XCTAssertEqual(document.cropRect, full, "one undo must undo the one visible crop")
        XCTAssertFalse(document.canUndo)
    }

    func testPixelAlignedRectRejectsEmptyAndNonIntersectingRects() {
        let imageSize = CGSize(width: 200, height: 100)
        XCTAssertNil(AnnotationDocument.pixelAlignedRect(.zero, imageSize: imageSize), "empty")
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 50, y: 50, width: 0, height: 10), imageSize: imageSize),
            "zero width"
        )
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 50, y: 50, width: 10, height: 0), imageSize: imageSize),
            "zero height"
        )
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 300, y: 10, width: 50, height: 50), imageSize: imageSize),
            "entirely right of the image"
        )
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: -100, y: -100, width: 50, height: 50), imageSize: imageSize),
            "entirely above and left of the image"
        )
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50), imageSize: imageSize),
            "non-finite"
        )
        XCTAssertNil(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 0, y: 0, width: 50, height: 50), imageSize: .zero),
            "degenerate image"
        )
    }

    func testPixelAlignedRectNormalisesAlignsAndClamps() {
        let imageSize = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 10.2, y: 20.7, width: 30.1, height: 40.4), imageSize: imageSize),
            CGRect(x: 10, y: 20, width: 31, height: 42)
        )
        // Dragged bottom-right to top-left, with fractions.
        XCTAssertEqual(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 40.3, y: 60.8, width: -30.1, height: -40.4), imageSize: imageSize),
            CGRect(x: 10, y: 20, width: 31, height: 41)
        )
        // Already integral rects are returned untouched.
        XCTAssertEqual(
            AnnotationDocument.pixelAlignedRect(CGRect(x: 10, y: 20, width: 30, height: 40), imageSize: imageSize),
            CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        // Partially outside: clamped, still integral.
        XCTAssertEqual(
            AnnotationDocument.pixelAlignedRect(CGRect(x: -5.5, y: -3.25, width: 40, height: 40), imageSize: imageSize),
            CGRect(x: 0, y: 0, width: 35, height: 37)
        )
    }

    func testCanonicalCropRectAppliesTheMinimumAfterAlignment() {
        let imageSize = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            AnnotationDocument.canonicalCropRect(CGRect(x: 10.5, y: 10.5, width: 15.2, height: 15.2), imageSize: imageSize),
            CGRect(x: 10, y: 10, width: 16, height: 16),
            "aligned size reaches the minimum"
        )
        XCTAssertNil(
            AnnotationDocument.canonicalCropRect(CGRect(x: 10.2, y: 10, width: 14.1, height: 40), imageSize: imageSize),
            "aligned size is still below the minimum"
        )
        XCTAssertNil(
            AnnotationDocument.canonicalCropRect(CGRect(x: 190.5, y: 10, width: 40, height: 40), imageSize: imageSize),
            "clamps down below the minimum"
        )
        XCTAssertEqual(
            AnnotationDocument.canonicalCropRect(CGRect(x: 0, y: 0, width: 200, height: 100), imageSize: imageSize),
            CGRect(x: 0, y: 0, width: 200, height: 100),
            "the full image is canonical"
        )
    }

    func testCycleSizeWrapsInBothDirections() throws {
        let document = try makeDocument()
        document.style.size = .small

        document.cycleSize(forward: true)
        XCTAssertEqual(document.style.size, .medium)
        document.cycleSize(forward: true)
        XCTAssertEqual(document.style.size, .large)
        document.cycleSize(forward: true)
        XCTAssertEqual(document.style.size, .small)

        document.cycleSize(forward: false)
        XCTAssertEqual(document.style.size, .large)
        document.cycleSize(forward: false)
        XCTAssertEqual(document.style.size, .medium)
        document.cycleSize(forward: false)
        XCTAssertEqual(document.style.size, .small)
    }

    func testCycleSizeLeavesTheColourAlone() throws {
        let document = try makeDocument()
        document.style.color = .blue
        document.cycleSize(forward: true)
        XCTAssertEqual(document.style.color, .blue)
        XCTAssertEqual(document.style.size, .large)
    }

    func testStyleDefaultsAndForwardedMetrics() {
        XCTAssertEqual(AnnotationStyle.default.color, .red)
        XCTAssertEqual(AnnotationStyle.default.size, .medium)
        XCTAssertEqual(AnnotationStyle.default.lineWidth, 8)
        XCTAssertEqual(AnnotationStyle.default.fontSize, 36)

        for size in AnnotationSize.allCases {
            let style = AnnotationStyle(color: .green, size: size)
            XCTAssertEqual(style.lineWidth, size.lineWidth)
            XCTAssertEqual(style.fontSize, size.fontSize)
        }
    }

    func testSizeMetricsAreTheDocumentedImagePixelValues() {
        XCTAssertEqual(AnnotationSize.allCases, [.small, .medium, .large])
        XCTAssertEqual(AnnotationSize.allCases.map(\.lineWidth), [4, 8, 14])
        XCTAssertEqual(AnnotationSize.allCases.map(\.fontSize), [24, 36, 56])
        XCTAssertEqual(AnnotationSize.allCases.map(\.title), ["Small", "Medium", "Large"])
        XCTAssertEqual(AnnotationSize.allCases.map(\.id), ["small", "medium", "large"])
    }

    func testToolKeyEquivalentsMatchCaseIterableOrder() {
        XCTAssertEqual(AnnotationTool.allCases, [.arrow, .box, .ellipse, .line, .text, .crop])
        XCTAssertEqual(AnnotationTool.allCases.map(\.keyEquivalent), ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(Set(AnnotationTool.allCases.map(\.keyEquivalent)).count, AnnotationTool.allCases.count)
        XCTAssertEqual(AnnotationTool.allCases.map(\.id), ["arrow", "box", "ellipse", "line", "text", "crop"])
        XCTAssertEqual(AnnotationTool.allCases.map(\.title), ["Arrow", "Box", "Ellipse", "Line", "Text", "Crop"])

        for (index, tool) in AnnotationTool.allCases.enumerated() {
            XCTAssertEqual(tool.keyEquivalent, String(index + 1))
        }
    }

    func testToolSymbolNamesResolveToRealSystemSymbols() {
        for tool in AnnotationTool.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil),
                "missing SF Symbol \(tool.symbolName)"
            )
        }
        XCTAssertEqual(Set(AnnotationTool.allCases.map(\.symbolName)).count, AnnotationTool.allCases.count)
    }

    func testColoursAreOpaqueSRGBAndDistinct() throws {
        XCTAssertEqual(
            AnnotationColor.allCases.map(\.id),
            ["red", "orange", "yellow", "green", "blue", "magenta", "white", "black"]
        )

        var components: Set<[CGFloat]> = []
        for color in AnnotationColor.allCases {
            let nsColor = color.nsColor
            XCTAssertEqual(nsColor.colorSpace.cgColorSpace?.name, CGColorSpace.sRGB, "\(color.rawValue)")
            XCTAssertEqual(nsColor.alphaComponent, 1.0, accuracy: 1e-9, "\(color.rawValue)")
            components.insert([nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent])
        }
        XCTAssertEqual(components.count, AnnotationColor.allCases.count)

        let white = AnnotationColor.white.nsColor
        XCTAssertEqual(white.redComponent, 1.0, accuracy: 1e-9)
        XCTAssertEqual(white.greenComponent, 1.0, accuracy: 1e-9)
        XCTAssertEqual(white.blueComponent, 1.0, accuracy: 1e-9)

        let black = AnnotationColor.black.nsColor
        XCTAssertEqual(black.redComponent, 0.0, accuracy: 1e-9)
        XCTAssertEqual(black.greenComponent, 0.0, accuracy: 1e-9)
        XCTAssertEqual(black.blueComponent, 0.0, accuracy: 1e-9)

        let red = AnnotationColor.red.nsColor
        XCTAssertEqual(red.redComponent, 1.0, accuracy: 1e-9)
        XCTAssertEqual(red.greenComponent, 0.20, accuracy: 1e-9)
        XCTAssertEqual(red.blueComponent, 0.20, accuracy: 1e-9)
    }

    func testAnnotationIdentityAndEquality() {
        let id = UUID()
        let first = Annotation(id: id, kind: .line(from: .zero, to: CGPoint(x: 10, y: 10)), style: .default)
        let second = Annotation(id: id, kind: .line(from: .zero, to: CGPoint(x: 10, y: 10)), style: .default)
        XCTAssertEqual(first, second)

        var third = first
        third.kind = .line(from: .zero, to: CGPoint(x: 11, y: 10))
        XCTAssertNotEqual(first, third)
        XCTAssertEqual(third.id, id)

        let fourth = Annotation(kind: first.kind, style: first.style)
        XCTAssertNotEqual(first, fourth)
    }

    func testTextAnnotationEqualityDistinguishesWrapWidth() {
        let id = UUID()
        let origin = CGPoint(x: 30, y: 40)
        func text(_ wrapWidth: CGFloat?) -> Annotation {
            Annotation(id: id, kind: .text(origin: origin, string: "two words", wrapWidth: wrapWidth), style: .default)
        }

        XCTAssertEqual(text(200), text(200), "same wrap width")
        // If these compared equal, undo/redo could silently collapse one layout into another.
        XCTAssertNotEqual(text(200), text(240), "different wrap widths")
        XCTAssertNotEqual(text(nil), text(200), "nil is not a numeric width")
        XCTAssertNotEqual(text(200), text(nil), "and the reverse")
        XCTAssertEqual(text(nil), text(nil), "both unwrapped")
    }

    func testWrapWidthSurvivesUndoAndRedo() throws {
        let document = try makeCroppableDocument()
        let wrapped = Annotation(kind: .text(origin: CGPoint(x: 5, y: 5), string: "a b c", wrapWidth: 120), style: .default)
        let unwrapped = Annotation(kind: .text(origin: CGPoint(x: 5, y: 60), string: "d e f", wrapWidth: nil), style: .default)

        document.append(wrapped)
        document.append(unwrapped)
        document.undo()
        document.undo()
        XCTAssertEqual(document.annotations, [])

        document.redo()
        document.redo()
        XCTAssertEqual(document.annotations, [wrapped, unwrapped])

        guard case let .text(_, _, wrapWidth) = document.annotations[0].kind else {
            return XCTFail("expected text, got \(document.annotations[0].kind)")
        }
        XCTAssertEqual(wrapWidth, 120)
        guard case let .text(_, _, missing) = document.annotations[1].kind else {
            return XCTFail("expected text, got \(document.annotations[1].kind)")
        }
        XCTAssertNil(missing)
    }
}
