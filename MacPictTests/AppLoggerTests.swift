import Foundation
import OSLog
import XCTest
@testable import MacPict

final class AppLoggerTests: XCTestCase {
    func testSubsystemIsTheAppBundleIdentifier() {
        XCTAssertEqual(AppLogger.subsystem, Bundle.main.bundleIdentifier)
        XCTAssertEqual(AppLogger.subsystem, "com.macpict.app")
    }

    func testEachLoggerUsesItsOwnCategory() {
        // Logger exposes neither its subsystem nor its category, but os_log
        // caches one log object per (subsystem, category) pair, so an
        // independently built Logger with the expected category reflects to the
        // same underlying object.
        let expected: [(Logger, String)] = [
            (AppLogger.app, "app"),
            (AppLogger.capture, "capture"),
            (AppLogger.annotation, "annotation"),
            (AppLogger.delivery, "delivery"),
            (AppLogger.hotkey, "hotkey"),
        ]

        for (logger, category) in expected {
            let reference = Logger(subsystem: AppLogger.subsystem, category: category)
            XCTAssertEqual(String(reflecting: logger), String(reflecting: reference), "category \(category)")
        }

        let identities = Set(expected.map { String(reflecting: $0.0) })
        XCTAssertEqual(identities.count, expected.count)
    }

    func testEveryLoggerIsUsable() {
        for logger in [AppLogger.app, AppLogger.capture, AppLogger.annotation, AppLogger.delivery, AppLogger.hotkey] {
            XCTAssertTrue(logger.isEnabled(type: .fault))
        }
    }
}
