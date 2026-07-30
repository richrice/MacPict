import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var hotkey: GlobalHotkeyManager

    init(settings: SettingsStore, hotkey: GlobalHotkeyManager) {
        self.settings = settings
        self.hotkey = hotkey
    }

    var body: some View {
        Form {
            Section("Capture shortcut") {
                Picker("Shortcut", selection: $settings.hotkey) {
                    ForEach(HotkeyShortcut.presetGroups) { group in
                        Section(group.name) {
                            ForEach(group.shortcuts) { shortcut in
                                Text(shortcut.displayString).tag(shortcut)
                            }
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(hotkey.status.displayText)
                        .fontWeight(statusNeedsAttention ? .semibold : .regular)
                        .foregroundStyle(statusNeedsAttention ? statusColor : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Restore Default (\(HotkeyShortcut.captureDefault.displayString))") {
                    settings.restoreDefaultHotkey()
                }
                Text("The shortcut works system-wide and takes effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("SSH delivery") {
                TextField("SSH target", text: $settings.sshTarget, prompt: Text("user@host or SSH alias"))
                    .textFieldStyle(.roundedBorder)
                Text("Uses your existing SSH configuration and key. Uploaded images go to ~/.cache/macpict on the Linux host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }

    private var statusSymbol: String {
        switch hotkey.status {
        case .registered: "checkmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .notRegistered: "minus.circle"
        }
    }

    private var statusColor: Color {
        switch hotkey.status {
        case .registered: .green
        case .conflict: .orange
        case .failed: .red
        case .notRegistered: .secondary
        }
    }

    // A conflict is the case the user has to act on — another app already owns the
    // combination — so it is coloured and weighted, not left as a quiet grey line.
    private var statusNeedsAttention: Bool {
        switch hotkey.status {
        case .conflict, .failed: true
        case .registered, .notRegistered: false
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: SettingsStore, hotkey: GlobalHotkeyManager) {
        let hostingController = NSHostingController(rootView: SettingsView(settings: settings, hotkey: hotkey))
        window = NSWindow(contentViewController: hostingController)
        window.title = "MacPict Settings"
        window.styleMask = [.titled, .closable]
        // The controller is retained and reused across openings; without this the
        // second show() would message a deallocated window.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MacPictSettingsWindow")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
