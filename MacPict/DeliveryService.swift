import AppKit
import Foundation
import UniformTypeIdentifiers

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
    func save(_ png: Data, to url: URL) throws
}

/// Asking the user where to put the PNG. Behind a protocol for one reason: the real
/// implementation puts a modal sheet on screen, and the coordinator's save path has to be
/// testable without one.
@MainActor
protocol SaveLocationRequesting: AnyObject {
    /// Returns the chosen location, or `nil` if the user cancelled — which is not a failure and
    /// must leave the snapshot exactly as it was.
    func requestSaveLocation(suggestedName: String, attachedTo window: NSWindow?) async -> URL?
}

@MainActor
final class SaveLocationPanel: SaveLocationRequesting {
    func requestSaveLocation(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Snapshot"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        // The extension is the one thing about the name that must not be a surprise: the bytes
        // are PNG whatever the field says, and an agent handed a `.txt` will not look at it.
        panel.isExtensionHidden = false
        // `directoryURL` is deliberately not set. AppKit restores the folder this app last saved
        // to, which is what every other Mac app does and the only useful answer from the second
        // save onwards; setting it would drag the user back to a fixed folder every time.

        // MacPict is an accessory with no Dock icon, so nothing else will bring it forward and a
        // panel the user cannot see is a hang as far as they are concerned.
        NSApp.activate()

        guard let window else {
            // No window to hang a sheet on — the app-modal panel is the honest fallback rather
            // than silently doing nothing.
            // The continuation is spelled out rather than inferred: the type it carries is only
            // otherwise visible two closures deep, inside the completion handler.
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                panel.begin { response in
                    MainActor.assumeIsolated {
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                }
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }
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

    /// Writes to a location the user picked, so unlike `copyFilePath` there is no name to
    /// invent, no directory to create and no collision to dodge: the save panel has already
    /// settled all three, overwrite confirmation included.
    func save(_ png: Data, to url: URL) throws {
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw DeliveryError.fileWriteFailed(
                "Could not write \(url.path): \(error.localizedDescription)"
            )
        }
        AppLogger.delivery.info(
            "Saved \(png.count, privacy: .public) PNG bytes to \(url.path, privacy: .public)"
        )
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
