import AppKit
import Foundation

enum DeliveryError: Error, Equatable {
    case pasteboardWriteFailed
    case fileWriteFailed(String)
}

enum DeliveryOutcome: Equatable, Sendable {
    case image
    case path(URL)
}

@MainActor
protocol SnapshotDelivering: AnyObject {
    func copyImage(_ png: Data) throws
    @discardableResult func copyFilePath(_ png: Data, timestamp: Date) throws -> URL
}

@MainActor
final class DeliveryService: SnapshotDelivering {
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacPict", isDirectory: true)
    }

    /// Pinned to en_US_POSIX so the name is stable and sortable whatever the user's locale is.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static func fileName(for timestamp: Date) -> String {
        fileName(for: timestamp, attempt: 0)
    }

    private static func fileName(for timestamp: Date, attempt: Int) -> String {
        let stamp = timestampFormatter.string(from: timestamp)
        return attempt == 0 ? "MacPict-\(stamp).png" : "MacPict-\(stamp)-\(attempt).png"
    }

    let directory: URL
    private let pasteboard: NSPasteboard

    init(directory: URL = DeliveryService.defaultDirectory, pasteboard: NSPasteboard = .general) {
        self.directory = directory
        self.pasteboard = pasteboard
    }

    func copyImage(_ png: Data) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppLogger.delivery.error("Pasteboard rejected the PNG representation")
            throw DeliveryError.pasteboardWriteFailed
        }

        // Some receivers only look for TIFF, so offer it alongside the caller's
        // untouched PNG bytes rather than instead of them.
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            if !pasteboard.setData(tiff, forType: .tiff) {
                AppLogger.delivery.error("Pasteboard rejected the TIFF representation")
            }
        } else {
            AppLogger.delivery.error("Could not derive a TIFF representation from the PNG")
        }

        AppLogger.delivery.info("Copied \(png.count, privacy: .public) PNG bytes to the pasteboard")
    }

    @discardableResult
    func copyFilePath(_ png: Data, timestamp: Date) throws -> URL {
        let url = try write(png, timestamp: timestamp)

        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string) else {
            AppLogger.delivery.error("Pasteboard rejected the snapshot path")
            throw DeliveryError.pasteboardWriteFailed
        }

        AppLogger.delivery.info("Wrote snapshot to \(url.path, privacy: .public) and copied its path")
        return url
    }

    private func write(_ png: Data, timestamp: Date) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DeliveryError.fileWriteFailed(
                "Could not create \(directory.path): \(error.localizedDescription)"
            )
        }

        // A second capture inside the same second must not land on the first
        // one's file, or the URL handed back would name someone else's bytes.
        var attempt = 0
        var url = directory.appendingPathComponent(Self.fileName(for: timestamp, attempt: attempt))
        while fileManager.fileExists(atPath: url.path) {
            attempt += 1
            url = directory.appendingPathComponent(Self.fileName(for: timestamp, attempt: attempt))
        }

        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw DeliveryError.fileWriteFailed(
                "Could not write \(url.path): \(error.localizedDescription)"
            )
        }
        return url
    }
}
