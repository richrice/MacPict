import Carbon.HIToolbox
import Foundation
import XCTest
@testable import MacPict

@MainActor
final class SettingsStoreTests: XCTestCase {
    private static let suiteName = "com.macpict.tests.settingsstore"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        // A suite of its own so a test run can never read or write the user's real preferences.
        let suite = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        suite.removePersistentDomain(forName: Self.suiteName)
        defaults = suite
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testFreshStoreUsesTheCaptureDefault() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hotkey, .captureDefault)
        XCTAssertNil(defaults.data(forKey: "captureHotkey"), "reading must not write")
    }

    func testAssigningTheHotkeyPersistsItImmediately() throws {
        let store = SettingsStore(defaults: defaults)
        let chosen = HotkeyShortcut(keyCode: UInt32(kVK_F13), carbonModifiers: 0, displayString: "F13")
        store.hotkey = chosen

        let data = try XCTUnwrap(defaults.data(forKey: "captureHotkey"))
        XCTAssertEqual(try JSONDecoder().decode(HotkeyShortcut.self, from: data), chosen)
    }

    func testAStoredHotkeyIsReadBackByASecondStoreOverTheSameDefaults() {
        let chosen = HotkeyShortcut(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(controlKey | shiftKey),
            displayString: "⌃⇧ Space"
        )
        SettingsStore(defaults: defaults).hotkey = chosen

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotkey, chosen)
        XCTAssertEqual(reloaded.hotkey.displayString, "⌃⇧ Space")
    }

    func testUndecodableStoredDataFallsBackToTheCaptureDefault() {
        defaults.set(Data("not json".utf8), forKey: "captureHotkey")
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkey, .captureDefault)
    }

    func testAStoredValueOfTheWrongTypeFallsBackToTheCaptureDefault() {
        defaults.set("⌃⌥ C", forKey: "captureHotkey")
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkey, .captureDefault)
    }

    func testRestoreDefaultHotkeyResetsAndPersists() {
        let store = SettingsStore(defaults: defaults)
        store.hotkey = HotkeyShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: 0, displayString: "F19")
        store.restoreDefaultHotkey()

        XCTAssertEqual(store.hotkey, .captureDefault)
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkey, .captureDefault)
    }
}
