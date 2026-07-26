import CoreGraphics
import XCTest
@testable import MacPict

final class DisplayLocatorTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testPointInsideASingleFrameResolvesToThatFrame() {
        XCTAssertEqual(DisplayLocator.indexOfScreen(containing: CGPoint(x: 960, y: 540), frames: [primary]), 0)
    }

    func testPointInsideTheSecondOfTwoFramesResolvesToTheSecond() {
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let index = DisplayLocator.indexOfScreen(containing: CGPoint(x: 3000, y: 700), frames: [primary, secondary])
        XCTAssertEqual(index, 1)
    }

    func testPointInNoFrameResolvesToNil() {
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        XCTAssertNil(DisplayLocator.indexOfScreen(containing: CGPoint(x: 5000, y: 700), frames: [primary, secondary]))
        XCTAssertNil(DisplayLocator.indexOfScreen(containing: CGPoint(x: 100, y: -1), frames: [primary, secondary]))
        XCTAssertNil(DisplayLocator.indexOfScreen(containing: CGPoint(x: 100, y: 100), frames: []))
    }

    func testPointOnTheSeamBetweenAbuttingFramesBelongsToTheFrameThatOwnsItsMinEdge() {
        // Documented behaviour: CGRect.contains is half-open, so the seam at
        // x == 1920 belongs to the right-hand display, not the left one.
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        XCTAssertFalse(primary.contains(CGPoint(x: 1920, y: 500)))
        XCTAssertTrue(secondary.contains(CGPoint(x: 1920, y: 500)))
        let index = DisplayLocator.indexOfScreen(containing: CGPoint(x: 1920, y: 500), frames: [primary, secondary])
        XCTAssertEqual(index, 1)

        // And when the two frames really do contain the same point (mirrored
        // displays), array order decides, so the earliest frame wins.
        let mirrored = DisplayLocator.indexOfScreen(containing: CGPoint(x: 10, y: 10), frames: [primary, primary])
        XCTAssertEqual(mirrored, 0)
    }

    func testNegativeOriginFramesResolveCorrectly() {
        // A display to the left of the primary and one above it. Both have
        // origins outside the primary's positive quadrant, which is exactly the
        // multi-monitor case a naive contains-check gets wrong.
        let left = CGRect(x: -2560, y: -180, width: 2560, height: 1440)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let frames = [primary, left, above]

        XCTAssertEqual(DisplayLocator.indexOfScreen(containing: CGPoint(x: -1280, y: 500), frames: frames), 1)
        XCTAssertEqual(DisplayLocator.indexOfScreen(containing: CGPoint(x: -10, y: -100), frames: frames), 1)
        XCTAssertEqual(DisplayLocator.indexOfScreen(containing: CGPoint(x: 960, y: 1500), frames: frames), 2)
        XCTAssertEqual(DisplayLocator.indexOfScreen(containing: CGPoint(x: 960, y: 540), frames: frames), 0)
        XCTAssertNil(DisplayLocator.indexOfScreen(containing: CGPoint(x: -3000, y: 500), frames: frames))
        XCTAssertNil(DisplayLocator.indexOfScreen(containing: CGPoint(x: 2000, y: 1500), frames: frames))
    }
}
