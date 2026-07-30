import AppKit
import Foundation
import XCTest
@testable import MacPict

@MainActor
final class DeliveryServiceTests: XCTestCase {
    private var directory: URL!
    private var sshFixtureDirectory: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        // Deliberately not created: several tests assert the service creates it.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPictDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        sshFixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPictSSHTests-\(UUID().uuidString)", isDirectory: true)
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
        if FileManager.default.fileExists(atPath: sshFixtureDirectory.path) {
            try FileManager.default.removeItem(at: sshFixtureDirectory)
        }
        sshFixtureDirectory = nil
        try await super.tearDown()
    }

    private func makeService(sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) -> DeliveryService {
        DeliveryService(
            directory: directory,
            pasteboard: pasteboard,
            sshExecutableURL: sshExecutableURL
        )
    }

    private func makeSSHExecutable(_ body: String, interpreter: String = "/bin/sh") throws -> URL {
        try FileManager.default.createDirectory(
            at: sshFixtureDirectory,
            withIntermediateDirectories: true
        )
        let executable = sshFixtureDirectory.appendingPathComponent("ssh")
        try "#!\(interpreter)\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func archivedPNGs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
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

    func testCopyImagePlacesByteIdenticalPNGDataOnThePasteboardAndDisk() throws {
        let png = try makePNG(red: 0.9)
        try makeService().copyImage(png)

        XCTAssertEqual(pasteboard.data(forType: .png), png)
        let archivedURLs = try archivedPNGs()
        XCTAssertEqual(archivedURLs.count, 1)
        let archived = try XCTUnwrap(archivedURLs.first)
        XCTAssertTrue(archived.lastPathComponent.hasPrefix("MacPict-"), archived.lastPathComponent)
        XCTAssertEqual(archived.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: archived), png)
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

    // MARK: - SSH upload

    func testUploadStreamsTheExactPNGAndCopiesTheReturnedRemotePath() async throws {
        let uploaded = sshFixtureDirectory.appendingPathComponent("uploaded.png")
        let remotePath = "/home/test/.cache/macpict/MacPict-2026-07-25-143012.png"
        let executable = try makeSSHExecutable(
            """
            cat > "\(uploaded.path)"
            printf '\(remotePath)'
            """
        )
        let png = try makePNG(red: 0.9)

        let result = try await makeService(sshExecutableURL: executable)
            .uploadAndCopyRemotePath(png, target: "devbox", timestamp: try fixedTimestamp())

        XCTAssertEqual(result, remotePath)
        XCTAssertEqual(try Data(contentsOf: uploaded), png)
        XCTAssertEqual(pasteboard.string(forType: .string), remotePath)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("MacPict-2026-07-25-143012.png")),
            png
        )
    }

    func testUploadCommandWorksWhenTheRemoteLoginShellIsZsh() async throws {
        let remoteHome = sshFixtureDirectory.appendingPathComponent("remote-home")
        let executable = try makeSSHExecutable(
            """
            export HOME="\(remoteHome.path)"
            unset XDG_CACHE_HOME
            eval "${@[-1]}"
            """,
            interpreter: "/bin/zsh"
        )
        let png = try makePNG(red: 0.9)
        let expectedPath = remoteHome
            .appendingPathComponent(".cache/macpict/MacPict-2026-07-25-143012.png")
            .path

        let result = try await makeService(sshExecutableURL: executable)
            .uploadAndCopyRemotePath(png, target: "devbox", timestamp: try fixedTimestamp())

        XCTAssertEqual(result, expectedPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expectedPath)), png)
    }

    func testUploadWithoutATargetFailsBeforeWritingAnything() async throws {
        do {
            _ = try await makeService().uploadAndCopyRemotePath(
                try makePNG(red: 0.9),
                target: "  ",
                timestamp: try fixedTimestamp()
            )
            XCTFail("Expected a missing-target error")
        } catch {
            XCTAssertEqual(error as? DeliveryError, .sshTargetMissing)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testUploadRejectsAnSSHTargetThatCouldBeParsedAsAnOption() async throws {
        do {
            _ = try await makeService().uploadAndCopyRemotePath(
                try makePNG(red: 0.9),
                target: "-oProxyCommand=anything",
                timestamp: try fixedTimestamp()
            )
            XCTFail("Expected an invalid-target error")
        } catch {
            XCTAssertEqual(error as? DeliveryError, .invalidSSHTarget)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSSHFailureReportsStderrAndDoesNotChangeThePasteboard() async throws {
        let executable = try makeSSHExecutable(
            """
            cat >/dev/null
            printf 'Permission denied' >&2
            exit 255
            """
        )

        do {
            _ = try await makeService(sshExecutableURL: executable).uploadAndCopyRemotePath(
                try makePNG(red: 0.9),
                target: "devbox",
                timestamp: try fixedTimestamp()
            )
            XCTFail("Expected SSH to fail")
        } catch {
            XCTAssertEqual(error as? DeliveryError, .sshUploadFailed("Permission denied"))
        }

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    // MARK: - Save As

    func testSaveWritesTheExactBytesToTheChosenURL() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try makePNG(red: 0.9)
        let destination = directory.appendingPathComponent("Somewhere Else.png")

        try makeService().save(png, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), png)
    }

    /// The panel has already asked the user whether to replace the file, so by the time the
    /// service sees it the answer is yes — a save that quietly refused would strand them.
    func testSaveReplacesAFileAlreadyAtTheChosenURL() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Taken.png")
        let first = try makePNG(red: 0.1)
        let second = try makePNG(red: 0.9)
        XCTAssertNotEqual(first, second)
        let service = makeService()

        try service.save(first, to: destination)
        try service.save(second, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), second)
    }

    /// Nothing else in the save path can fail, so this is the one error the coordinator has to
    /// be able to show — and it has to name the file the user picked.
    func testSaveReportsAFileWriteFailureNamingTheChosenPath() throws {
        // The directory is deliberately never created, so the write has nowhere to land.
        let destination = directory.appendingPathComponent("Nowhere.png")

        XCTAssertThrowsError(try makeService().save(try makePNG(red: 0.9), to: destination)) { error in
            guard case .fileWriteFailed(let message) = error as? DeliveryError else {
                return XCTFail("Expected fileWriteFailed, got \(error)")
            }
            XCTAssertTrue(message.contains(destination.path), message)
        }
    }

    /// Save As writes where it is told and nowhere else: the automatic archive directory must
    /// not be created as a side effect, and the clipboard must be left alone.
    func testSaveTouchesNeitherTheAutomaticArchiveDirectoryNorThePasteboard() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPictSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let destination = elsewhere.appendingPathComponent("Chosen.png")

        try makeService().save(try makePNG(red: 0.9), to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testDefaultDirectoryIsTheScreenshotsFolderInsidePictures() throws {
        let pictures = try XCTUnwrap(
            FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        )
        XCTAssertEqual(
            DeliveryService.defaultDirectory.path,
            pictures.appendingPathComponent("Screenshots").path
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

    func testCopyImageDoesNotTouchThePasteboardWhenItsArchiveCannotBeWritten() throws {
        // A regular file where the directory should be makes createDirectory fail.
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try makeService().copyImage(try makePNG(red: 0.9))) { error in
            guard case .fileWriteFailed(let message) = error as? DeliveryError else {
                return XCTFail("Expected fileWriteFailed, got \(error)")
            }
            XCTAssertTrue(message.contains(self.directory.path), message)
        }
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.data(forType: .tiff))
    }
}
