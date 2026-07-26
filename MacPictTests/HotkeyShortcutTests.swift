import Carbon.HIToolbox
import XCTest
@testable import MacPict

final class HotkeyShortcutTests: XCTestCase {
    func testCaptureDefaultIsControlOptionC() {
        let shortcut = HotkeyShortcut.captureDefault
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(shortcut.carbonModifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(shortcut.displayString, "⌃⌥ C")
    }

    func testCaptureDefaultCarriesNoModifierBeyondControlOption() {
        let modifiers = HotkeyShortcut.captureDefault.carbonModifiers
        XCTAssertEqual(modifiers & UInt32(controlKey), UInt32(controlKey))
        XCTAssertEqual(modifiers & UInt32(optionKey), UInt32(optionKey))
        XCTAssertEqual(modifiers & UInt32(cmdKey), 0, "command must not be part of the capture shortcut")
        XCTAssertEqual(modifiers & UInt32(shiftKey), 0, "shift must not be part of the capture shortcut")
        XCTAssertEqual(modifiers & UInt32(alphaLock), 0)
        XCTAssertEqual(modifiers & ~UInt32(controlKey | optionKey), 0)
    }

    func testPresetGroupsContainTheDefault() {
        let presets = HotkeyShortcut.presetGroups.flatMap(\.shortcuts)
        XCTAssertTrue(presets.contains(.captureDefault))
    }

    func testEveryPresetHasAUniqueIdentifier() {
        let presets = HotkeyShortcut.presetGroups.flatMap(\.shortcuts)
        let identifiers = Set(presets.map(\.id))
        XCTAssertEqual(identifiers.count, presets.count, "duplicate presets would break Picker selection")
    }

    func testEveryPresetHasANonEmptyDisplayString() {
        for preset in HotkeyShortcut.presetGroups.flatMap(\.shortcuts) {
            XCTAssertFalse(preset.displayString.isEmpty, "preset \(preset.id) has no label")
        }
    }

    func testNoPresetIsOptionSpaceAlone() {
        let presets = HotkeyShortcut.presetGroups.flatMap(\.shortcuts)
        let collision = presets.first {
            $0.keyCode == UInt32(kVK_Space) && $0.carbonModifiers == UInt32(optionKey)
        }
        XCTAssertNil(collision, "⌥ Space is MacDictate's default and would conflict on this user's machine")
    }

    func testGroupNamesAreUnique() {
        let names = HotkeyShortcut.presetGroups.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testRegistrationStatusReportsTheAttemptedShortcut() {
        XCTAssertEqual(HotkeyRegistrationStatus.notRegistered.displayText, "Not registered")
        XCTAssertTrue(HotkeyRegistrationStatus.registered("⌃⌥ C").isRegistered)
        XCTAssertFalse(HotkeyRegistrationStatus.conflict("⌃⌥ C").isRegistered)
        XCTAssertFalse(HotkeyRegistrationStatus.failed("Carbon error -50").isRegistered)
        XCTAssertTrue(HotkeyRegistrationStatus.conflict("⌃⌥ C").displayText.contains("⌃⌥ C"))
        XCTAssertTrue(HotkeyRegistrationStatus.failed("Carbon error -50").displayText.contains("-50"))
    }

    // These two touch no Carbon registration: a fresh manager installs nothing until `register(_:)`
    // is called, and `unregister()` on it has no live hotkey to release. Anything beyond this would
    // need a real `RegisterEventHotKey`, which is process-global state and would make the suite flaky.
    @MainActor
    func testAFreshManagerHasNoActiveShortcut() {
        let manager = GlobalHotkeyManager()
        XCTAssertNil(manager.activeShortcut)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    @MainActor
    func testUnregisterLeavesNoActiveShortcut() {
        let manager = GlobalHotkeyManager()
        manager.unregister()
        XCTAssertNil(manager.activeShortcut)
        XCTAssertEqual(manager.status, .notRegistered)
    }
}
