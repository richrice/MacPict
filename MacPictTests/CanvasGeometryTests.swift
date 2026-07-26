import CoreGraphics
import XCTest
@testable import MacPict

final class CanvasGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 1e-9

    private func assertEqual(
        _ point: CGPoint,
        _ expected: CGPoint,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(point.x, expected.x, accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: accuracy, "y \(message)", file: file, line: line)
    }

    func testWiderThanViewImageIsLetterboxed() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(geometry.displayRect, CGRect(x: 0, y: 50, width: 400, height: 300))
        XCTAssertEqual(geometry.imageScale, 2, accuracy: accuracy)
    }

    func testTallerThanViewImageIsPillarboxed() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 600, height: 800), viewSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(geometry.displayRect, CGRect(x: 50, y: 0, width: 300, height: 400))
        XCTAssertEqual(geometry.imageScale, 2, accuracy: accuracy)
    }

    func testDisplayRectCornersMapToTheImageCorners() {
        let imageSize = CGSize(width: 1000, height: 500)
        let geometry = CanvasGeometry(imageSize: imageSize, viewSize: CGSize(width: 300, height: 300))
        let rect = geometry.displayRect
        XCTAssertEqual(rect, CGRect(x: 0, y: 75, width: 300, height: 150))

        assertEqual(geometry.imagePoint(fromView: CGPoint(x: rect.minX, y: rect.minY)), .zero, "top-left")
        assertEqual(
            geometry.imagePoint(fromView: CGPoint(x: rect.maxX, y: rect.minY)),
            CGPoint(x: imageSize.width, y: 0),
            "top-right"
        )
        assertEqual(
            geometry.imagePoint(fromView: CGPoint(x: rect.minX, y: rect.maxY)),
            CGPoint(x: 0, y: imageSize.height),
            "bottom-left"
        )
        assertEqual(
            geometry.imagePoint(fromView: CGPoint(x: rect.maxX, y: rect.maxY)),
            CGPoint(x: imageSize.width, y: imageSize.height),
            "bottom-right"
        )

        assertEqual(geometry.viewPoint(fromImage: .zero), CGPoint(x: rect.minX, y: rect.minY), "image origin")
        assertEqual(
            geometry.viewPoint(fromImage: CGPoint(x: imageSize.width, y: imageSize.height)),
            CGPoint(x: rect.maxX, y: rect.maxY),
            "image far corner"
        )
    }

    func testViewAndImagePointsAreExactInversesForInteriorPoints() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 2560, height: 1600), viewSize: CGSize(width: 900, height: 700))
        let rect = geometry.displayRect

        let viewPoints = [
            CGPoint(x: rect.minX + 1, y: rect.minY + 1),
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.minX + 123.5, y: rect.minY + 45.25),
            CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)
        ]
        for point in viewPoints {
            assertEqual(geometry.viewPoint(fromImage: geometry.imagePoint(fromView: point)), point, "view round trip")
        }

        let imagePoints = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1280, y: 800),
            CGPoint(x: 2559.5, y: 1599.5),
            CGPoint(x: 137, y: 942)
        ]
        for point in imagePoints {
            assertEqual(geometry.imagePoint(fromView: geometry.viewPoint(fromImage: point)), point, "image round trip")
        }
    }

    func testRectConversionsRoundTrip() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 1200, height: 900), viewSize: CGSize(width: 600, height: 600))
        XCTAssertEqual(geometry.displayRect, CGRect(x: 0, y: 75, width: 600, height: 450))
        XCTAssertEqual(geometry.imageScale, 2, accuracy: accuracy)

        let viewRect = CGRect(x: 100, y: 175, width: 50, height: 25)
        let imageRect = geometry.imageRect(fromView: viewRect)
        XCTAssertEqual(imageRect, CGRect(x: 200, y: 200, width: 100, height: 50))

        let backToView = geometry.viewRect(fromImage: imageRect)
        XCTAssertEqual(backToView.minX, viewRect.minX, accuracy: accuracy)
        XCTAssertEqual(backToView.minY, viewRect.minY, accuracy: accuracy)
        XCTAssertEqual(backToView.width, viewRect.width, accuracy: accuracy)
        XCTAssertEqual(backToView.height, viewRect.height, accuracy: accuracy)
    }

    func testNoYInversionInEitherDirection() {
        // Both spaces are top-left origin, so a point near the top of the image must map
        // near the top of the display rect — an inversion would land it near the bottom.
        let geometry = CanvasGeometry(imageSize: CGSize(width: 400, height: 400), viewSize: CGSize(width: 200, height: 200))
        let nearTop = geometry.viewPoint(fromImage: CGPoint(x: 200, y: 40))
        assertEqual(nearTop, CGPoint(x: 100, y: 20))
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: 100, y: 20)), CGPoint(x: 200, y: 40))
    }

    func testDegenerateViewSizeIsSafe() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: .zero)
        XCTAssertEqual(geometry.displayRect, .zero)
        XCTAssertEqual(geometry.imageScale, 1)

        let mapped = geometry.imagePoint(fromView: CGPoint(x: 10, y: 20))
        assertEqual(mapped, CGPoint(x: 10, y: 20))
        XCTAssertFalse(mapped.x.isNaN)
        XCTAssertFalse(mapped.y.isNaN)

        let back = geometry.viewPoint(fromImage: mapped)
        assertEqual(back, CGPoint(x: 10, y: 20))

        let rect = geometry.imageRect(fromView: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(rect, CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testOtherDegenerateSizesAreSafe() {
        let degenerate = [
            CanvasGeometry(imageSize: .zero, viewSize: CGSize(width: 400, height: 300)),
            CanvasGeometry(imageSize: CGSize(width: 800, height: 0), viewSize: CGSize(width: 400, height: 300)),
            CanvasGeometry(imageSize: CGSize(width: -800, height: 600), viewSize: CGSize(width: 400, height: 300)),
            CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: -300)),
            CanvasGeometry(imageSize: CGSize(width: CGFloat.infinity, height: 600), viewSize: CGSize(width: 400, height: 300)),
            CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: CGFloat.nan, height: 300))
        ]
        for geometry in degenerate {
            XCTAssertEqual(geometry.displayRect, CGRect.zero)
            XCTAssertEqual(geometry.imageScale, 1)
            let point = geometry.imagePoint(fromView: CGPoint(x: 7, y: 9))
            XCTAssertEqual(point.x, 7, accuracy: accuracy)
            XCTAssertEqual(point.y, 9, accuracy: accuracy)
        }
    }

    func testClampToImageBoundsAllFourSides() {
        let geometry = CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: 400))

        XCTAssertEqual(geometry.clampToImage(CGPoint(x: -12, y: 300)), CGPoint(x: 0, y: 300), "left")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 900, y: 300)), CGPoint(x: 800, y: 300), "right")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 400, y: -5)), CGPoint(x: 400, y: 0), "top")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 400, y: 601)), CGPoint(x: 400, y: 600), "bottom")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: -1, y: -1)), .zero, "top-left corner")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 1000, y: 1000)), CGPoint(x: 800, y: 600), "bottom-right corner")
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 123.5, y: 45.25)), CGPoint(x: 123.5, y: 45.25), "interior")
    }

    func testTwoArgumentInitialiserUsesTheFullImageAsItsSource() {
        let imageSize = CGSize(width: 800, height: 600)
        let viewSize = CGSize(width: 400, height: 400)
        let implicit = CanvasGeometry(imageSize: imageSize, viewSize: viewSize)
        XCTAssertEqual(implicit.sourceRect, CGRect(origin: .zero, size: imageSize))
        XCTAssertEqual(
            implicit,
            CanvasGeometry(imageSize: imageSize, sourceRect: CGRect(origin: .zero, size: imageSize), viewSize: viewSize)
        )
        XCTAssertNotEqual(
            implicit,
            CanvasGeometry(imageSize: imageSize, sourceRect: CGRect(x: 10, y: 10, width: 100, height: 100), viewSize: viewSize)
        )
    }

    func testSourceRectIsAspectFitAndImagePointsStayFullImage() {
        let geometry = CanvasGeometry(
            imageSize: CGSize(width: 800, height: 600),
            sourceRect: CGRect(x: 200, y: 100, width: 400, height: 300),
            viewSize: CGSize(width: 400, height: 400)
        )
        // The 400×300 source fits at scale 1, centred vertically in the 400×400 view.
        XCTAssertEqual(geometry.displayRect, CGRect(x: 0, y: 50, width: 400, height: 300))
        XCTAssertEqual(geometry.imageScale, 1, accuracy: accuracy)

        // Full-image coordinates come back out, offset by the source origin.
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: 0, y: 50)), CGPoint(x: 200, y: 100), "source top-left")
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: 10, y: 60)), CGPoint(x: 210, y: 110), "interior")
        assertEqual(geometry.viewPoint(fromImage: CGPoint(x: 210, y: 110)), CGPoint(x: 10, y: 60), "interior reverse")
    }

    func testDisplayRectCornersMapToTheSourceRectCorners() {
        let source = CGRect(x: 300, y: 150, width: 500, height: 250)
        let geometry = CanvasGeometry(
            imageSize: CGSize(width: 1200, height: 800),
            sourceRect: source,
            viewSize: CGSize(width: 250, height: 250)
        )
        let rect = geometry.displayRect
        XCTAssertEqual(rect, CGRect(x: 0, y: 62.5, width: 250, height: 125))
        XCTAssertEqual(geometry.imageScale, 2, accuracy: accuracy)

        assertEqual(geometry.imagePoint(fromView: CGPoint(x: rect.minX, y: rect.minY)), CGPoint(x: source.minX, y: source.minY), "top-left")
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: rect.maxX, y: rect.minY)), CGPoint(x: source.maxX, y: source.minY), "top-right")
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: rect.minX, y: rect.maxY)), CGPoint(x: source.minX, y: source.maxY), "bottom-left")
        assertEqual(geometry.imagePoint(fromView: CGPoint(x: rect.maxX, y: rect.maxY)), CGPoint(x: source.maxX, y: source.maxY), "bottom-right")

        assertEqual(geometry.viewPoint(fromImage: CGPoint(x: source.minX, y: source.minY)), CGPoint(x: rect.minX, y: rect.minY), "source origin")
        assertEqual(geometry.viewPoint(fromImage: CGPoint(x: source.maxX, y: source.maxY)), CGPoint(x: rect.maxX, y: rect.maxY), "source far corner")
    }

    func testConversionsRemainExactInversesUnderANonZeroSourceOrigin() {
        let geometry = CanvasGeometry(
            imageSize: CGSize(width: 2560, height: 1600),
            sourceRect: CGRect(x: 137, y: 942, width: 653, height: 411),
            viewSize: CGSize(width: 500, height: 300)
        )
        let rect = geometry.displayRect

        for point in [
            CGPoint(x: rect.minX + 1, y: rect.minY + 1),
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.minX + 87.25, y: rect.minY + 33.75),
            CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)
        ] {
            assertEqual(geometry.viewPoint(fromImage: geometry.imagePoint(fromView: point)), point, "view round trip")
        }

        for point in [
            CGPoint(x: 137, y: 942),
            CGPoint(x: 463.5, y: 1147.5),
            CGPoint(x: 789.5, y: 1352.5)
        ] {
            assertEqual(geometry.imagePoint(fromView: geometry.viewPoint(fromImage: point)), point, "image round trip")
        }

        // A view point inside the display rect always maps inside the source rect.
        let mapped = geometry.imagePoint(fromView: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(geometry.sourceRect.contains(mapped))
    }

    func testCroppedRectConversionsCarryTheSourceOrigin() {
        let geometry = CanvasGeometry(
            imageSize: CGSize(width: 1000, height: 1000),
            sourceRect: CGRect(x: 100, y: 200, width: 400, height: 400),
            viewSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(geometry.displayRect, CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(geometry.imageScale, 2, accuracy: accuracy)

        XCTAssertEqual(geometry.imageRect(fromView: CGRect(x: 10, y: 20, width: 30, height: 40)),
                       CGRect(x: 120, y: 240, width: 60, height: 80))
        XCTAssertEqual(geometry.viewRect(fromImage: CGRect(x: 120, y: 240, width: 60, height: 80)),
                       CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testDegenerateSourceRectsAreSafe() {
        let imageSize = CGSize(width: 800, height: 600)
        let viewSize = CGSize(width: 400, height: 300)
        let degenerate = [
            CGRect.zero,
            CGRect(x: 100, y: 100, width: 0, height: 200),
            CGRect(x: 100, y: 100, width: 200, height: 0),
            CGRect(x: -10, y: 0, width: 200, height: 200),
            CGRect(x: 700, y: 0, width: 200, height: 200),
            CGRect(x: 0, y: 500, width: 200, height: 200),
            CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)
        ]
        for sourceRect in degenerate {
            let geometry = CanvasGeometry(imageSize: imageSize, sourceRect: sourceRect, viewSize: viewSize)
            XCTAssertEqual(geometry.displayRect, CGRect.zero, "\(sourceRect)")
            XCTAssertEqual(geometry.imageScale, 1, "\(sourceRect)")

            let point = geometry.imagePoint(fromView: CGPoint(x: 7, y: 9))
            XCTAssertEqual(point.x, 7, accuracy: accuracy, "\(sourceRect)")
            XCTAssertEqual(point.y, 9, accuracy: accuracy, "\(sourceRect)")
            XCTAssertFalse(point.x.isNaN)
            XCTAssertFalse(point.y.isNaN)
        }
    }

    func testClampToImageStillBoundsToTheFullImageWhenCropped() {
        let geometry = CanvasGeometry(
            imageSize: CGSize(width: 800, height: 600),
            sourceRect: CGRect(x: 100, y: 100, width: 200, height: 200),
            viewSize: CGSize(width: 400, height: 400)
        )
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 700, y: 500)), CGPoint(x: 700, y: 500))
        XCTAssertEqual(geometry.clampToImage(CGPoint(x: 900, y: -3)), CGPoint(x: 800, y: 0))
    }

    func testEquatableUsesBothStoredSizes() {
        let base = CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(base, CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: 400)))
        XCTAssertNotEqual(base, CanvasGeometry(imageSize: CGSize(width: 801, height: 600), viewSize: CGSize(width: 400, height: 400)))
        XCTAssertNotEqual(base, CanvasGeometry(imageSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 400, height: 401)))
    }
}
