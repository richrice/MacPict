import Carbon.HIToolbox
import Combine
import Foundation

struct HotkeyPresetGroup: Identifiable, Sendable {
    let name: String
    let shortcuts: [HotkeyShortcut]

    var id: String { name }
}

struct HotkeyShortcut: Codable, Hashable, Identifiable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String

    var id: String { "\(keyCode)-\(carbonModifiers)" }

    // Two adjacent left-hand modifiers plus a letter that sits under the index finger,
    // so the capture chord is comfortably one-handed; C is mnemonic for Capture.
    static let captureDefault = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        carbonModifiers: UInt32(controlKey | optionKey),
        displayString: "⌃⌥ C"
    )

    // A curated list, not a shortcut recorder: every entry is known to be typeable with one
    // hand and its glyphs are written out here rather than derived from a keycode table.
    //
    // Plain "⌥ Space" is deliberately absent. It is MacDictate's default shortcut and this
    // user runs both apps, so offering it here would hand them a guaranteed conflict.
    static let presetGroups: [HotkeyPresetGroup] = [
        HotkeyPresetGroup(name: "Letters", shortcuts: [
            .captureDefault,
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(optionKey), displayString: "⌥ C"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey), displayString: "⌃⌥ S"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey), displayString: "⌥ S"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey), displayString: "⌃⌥ A")
        ]),
        HotkeyPresetGroup(name: "Space", shortcuts: [
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey), displayString: "⌃ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), displayString: "⌃⌥ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⌘⇧ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), displayString: "⌥⇧ Space"),
            HotkeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | shiftKey), displayString: "⌃⇧ Space")
        ]),
        // Unmodified function keys are the easiest one-handed options of all on a full keyboard.
        HotkeyPresetGroup(name: "Function keys", shortcuts: [
            HotkeyShortcut(keyCode: UInt32(kVK_F13), carbonModifiers: 0, displayString: "F13"),
            HotkeyShortcut(keyCode: UInt32(kVK_F14), carbonModifiers: 0, displayString: "F14"),
            HotkeyShortcut(keyCode: UInt32(kVK_F15), carbonModifiers: 0, displayString: "F15"),
            HotkeyShortcut(keyCode: UInt32(kVK_F16), carbonModifiers: 0, displayString: "F16"),
            HotkeyShortcut(keyCode: UInt32(kVK_F17), carbonModifiers: 0, displayString: "F17"),
            HotkeyShortcut(keyCode: UInt32(kVK_F18), carbonModifiers: 0, displayString: "F18"),
            HotkeyShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: 0, displayString: "F19")
        ]),
        HotkeyPresetGroup(name: "Screenshot style", shortcuts: [
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), displayString: "⌃⌥⌘ 4"),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⇧⌘ 2")
        ])
    ]
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let hotkey = "captureHotkey"
    }

    private let defaults: UserDefaults

    /// Fires after `hotkey` has been stored and persisted, unlike `$hotkey`, which publishes from
    /// `willSet`. A subscriber that writes a corrected value back must use this one, or its write
    /// is flattened by the assignment still in flight.
    let hotkeyDidChange = PassthroughSubject<HotkeyShortcut, Never>()

    // Persist before sending: a subscriber that writes back triggers a nested `didSet` whose
    // `persistHotkey()` completes before this one returns, so the corrected value is the last
    // thing written to UserDefaults. Sending first would leave the rejected shortcut persisted.
    @Published var hotkey: HotkeyShortcut {
        didSet {
            persistHotkey()
            hotkeyDidChange.send(hotkey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.hotkey),
           let decoded = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .captureDefault
        }
    }

    func restoreDefaultHotkey() {
        hotkey = .captureDefault
    }

    private func persistHotkey() {
        guard let data = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(data, forKey: Key.hotkey)
    }
}
