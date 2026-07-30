import Carbon.HIToolbox
import Combine
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
        XCTAssertEqual(store.sshTarget, "")
        XCTAssertNil(defaults.data(forKey: "captureHotkey"), "reading must not write")
        XCTAssertNil(defaults.string(forKey: "sshTarget"), "reading must not write")
    }

    func testSSHTargetPersistsImmediately() {
        let store = SettingsStore(defaults: defaults)
        store.sshTarget = "devbox"

        XCTAssertEqual(defaults.string(forKey: "sshTarget"), "devbox")
        XCTAssertEqual(SettingsStore(defaults: defaults).sshTarget, "devbox")
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

    func testHotkeyDidChangeFiresAfterTheNewValueIsReadable() {
        let store = SettingsStore(defaults: defaults)
        let chosen = HotkeyShortcut(keyCode: UInt32(kVK_F14), carbonModifiers: 0, displayString: "F14")
        var observed: [HotkeyShortcut] = []
        var valueInsideSink: HotkeyShortcut?

        // `$hotkey` publishes from willSet and would still report the old value here.
        let cancellable = store.hotkeyDidChange.sink { shortcut in
            observed.append(shortcut)
            valueInsideSink = store.hotkey
        }
        store.hotkey = chosen
        cancellable.cancel()

        XCTAssertEqual(observed, [chosen])
        XCTAssertEqual(valueInsideSink, chosen, "the subject must fire after the value is stored")
    }

    func testHotkeyDidChangeFiresAfterTheNewValueIsPersisted() {
        let store = SettingsStore(defaults: defaults)
        let chosen = HotkeyShortcut(keyCode: UInt32(kVK_F15), carbonModifiers: 0, displayString: "F15")
        var reloadedInsideSink: HotkeyShortcut?

        let cancellable = store.hotkeyDidChange.sink { [defaults] _ in
            reloadedInsideSink = SettingsStore(defaults: defaults!).hotkey
        }
        store.hotkey = chosen
        cancellable.cancel()

        XCTAssertEqual(reloadedInsideSink, chosen, "persistence must complete before the subject fires")
    }

    func testASynchronousWriteBackInsideTheSinkSurvives() {
        let store = SettingsStore(defaults: defaults)
        let rejected = HotkeyShortcut(keyCode: UInt32(kVK_F16), carbonModifiers: 0, displayString: "F16")
        let corrected = HotkeyShortcut(keyCode: UInt32(kVK_F17), carbonModifiers: 0, displayString: "F17")
        var hasWrittenBack = false

        // The coordinator's exact move: a registration failed, so it puts the working shortcut
        // back synchronously. It must survive the assignment that is still unwinding.
        let cancellable = store.hotkeyDidChange.sink { _ in
            guard !hasWrittenBack else { return }
            hasWrittenBack = true
            store.hotkey = corrected
        }
        store.hotkey = rejected
        cancellable.cancel()

        XCTAssertTrue(hasWrittenBack)
        XCTAssertEqual(store.hotkey, corrected)
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkey, corrected, "the rejected shortcut must not stay persisted")
    }

    func testRestoreDefaultHotkeyResetsAndPersists() {
        let store = SettingsStore(defaults: defaults)
        store.hotkey = HotkeyShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: 0, displayString: "F19")
        store.restoreDefaultHotkey()

        XCTAssertEqual(store.hotkey, .captureDefault)
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkey, .captureDefault)
    }
}
