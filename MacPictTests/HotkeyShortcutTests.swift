import Carbon.HIToolbox
import XCTest
@testable import MacPict

final class HotkeyShortcutTests: XCTestCase {
    func testCaptureDefaultIsControlOptionCommandFour() {
        let shortcut = HotkeyShortcut.captureDefault
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_4))
        XCTAssertEqual(shortcut.carbonModifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(shortcut.displayString, "⌃⌥⌘4")
    }

    func testCaptureDefaultCarriesNoModifierBeyondControlOptionCommand() {
        let modifiers = HotkeyShortcut.captureDefault.carbonModifiers
        XCTAssertEqual(modifiers & UInt32(controlKey), UInt32(controlKey))
        XCTAssertEqual(modifiers & UInt32(optionKey), UInt32(optionKey))
        XCTAssertEqual(modifiers & UInt32(cmdKey), UInt32(cmdKey))
        XCTAssertEqual(modifiers & UInt32(shiftKey), 0, "shift must not be part of the capture shortcut")
        XCTAssertEqual(modifiers & UInt32(alphaLock), 0)
        XCTAssertEqual(modifiers & ~UInt32(controlKey | optionKey | cmdKey), 0)
    }
}
