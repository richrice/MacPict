import AppKit
import Foundation
import XCTest
@testable import MacPict

@MainActor
final class DeliveryServiceTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        // Deliberately not created: several tests assert the service creates it.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPictDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        // A uniquely named pasteboard, never NSPasteboard.general, so a test run
        // cannot clobber the user's real clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.macpict.tests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try await super.tearDown()
    }

    private func makeService() -> DeliveryService {
        DeliveryService(directory: directory, pasteboard: pasteboard)
    }

    /// A real, decodable PNG whose bytes differ per `red` value.
    private func makePNG(red: CGFloat) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: red, green: 0.25, blue: 0.5, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 4, height: 3)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func fixedTimestamp() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let components = DateComponents(year: 2026, month: 7, day: 25, hour: 14, minute: 30, second: 12)
        return try XCTUnwrap(calendar.date(from: components))
    }

    func testCopyImagePlacesByteIdenticalPNGDataOnThePasteboard() throws {
        let png = try makePNG(red: 0.9)
        try makeService().copyImage(png)

        XCTAssertEqual(pasteboard.data(forType: .png), png)
    }

    func testCopyImageAlsoProvidesATIFFRepresentation() throws {
        let png = try makePNG(red: 0.9)
        try makeService().copyImage(png)

        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(rep.pixelsWide, 4)
        XCTAssertEqual(rep.pixelsHigh, 3)
    }

    func testCopyFilePathWritesTheExactBytesToDisk() throws {
        let png = try makePNG(red: 0.9)
        let url = try makeService().copyFilePath(png, timestamp: try fixedTimestamp())

        XCTAssertEqual(url, directory.appendingPathComponent("MacPict-2026-07-25-143012.png"))
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testCopyFilePathPutsThePOSIXPathOnThePasteboardAsAString() throws {
        let png = try makePNG(red: 0.9)
        let url = try makeService().copyFilePath(png, timestamp: try fixedTimestamp())

        XCTAssertEqual(pasteboard.string(forType: .string), url.path)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testFileNameIsStableForAFixedDate() throws {
        XCTAssertEqual(DeliveryService.fileName(for: try fixedTimestamp()), "MacPict-2026-07-25-143012.png")
    }

    func testDirectoryIsCreatedWhenAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try makeService().copyFilePath(try makePNG(red: 0.9), timestamp: try fixedTimestamp())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testTwoCapturesInTheSameSecondEachKeepTheirOwnBytes() throws {
        let service = makeService()
        let timestamp = try fixedTimestamp()
        let first = try makePNG(red: 0.1)
        let second = try makePNG(red: 0.9)
        XCTAssertNotEqual(first, second)

        let firstURL = try service.copyFilePath(first, timestamp: timestamp)
        let secondURL = try service.copyFilePath(second, timestamp: timestamp)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), first)
        XCTAssertEqual(try Data(contentsOf: secondURL), second)
        XCTAssertEqual(secondURL.lastPathComponent, "MacPict-2026-07-25-143012-1.png")
        XCTAssertEqual(pasteboard.string(forType: .string), secondURL.path)
    }

    func testDefaultDirectoryIsTheTemporaryMacPictFolder() {
        XCTAssertEqual(
            DeliveryService.defaultDirectory.path,
            FileManager.default.temporaryDirectory.appendingPathComponent("MacPict").path
        )
    }

    func testDeliveryOutcomeDistinguishesImageFromPath() {
        let url = URL(fileURLWithPath: "/tmp/MacPict/MacPict-2026-07-25-143012.png")
        XCTAssertEqual(DeliveryOutcome.path(url), .path(url))
        XCTAssertNotEqual(DeliveryOutcome.path(url), .image)
    }

    func testFileWriteFailureIsReportedWhenTheDirectoryIsNotWritable() throws {
        // A regular file where the directory should be makes createDirectory fail.
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try makeService().copyFilePath(try makePNG(red: 0.9), timestamp: try fixedTimestamp())) { error in
            guard case .fileWriteFailed(let message) = error as? DeliveryError else {
                return XCTFail("Expected fileWriteFailed, got \(error)")
            }
            XCTAssertTrue(message.contains(self.directory.path), message)
        }
    }
}
