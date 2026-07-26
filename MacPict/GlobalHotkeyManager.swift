import Carbon.HIToolbox
import Foundation

struct HotkeyShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String

    static let captureDefault = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        displayString: "⌃⌥⌘4"
    )
}

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case failed(OSStatus)
}

@MainActor
final class GlobalHotkeyManager {
    var onTrigger: (() -> Void)?
    private(set) var status: HotkeyRegistrationStatus?

    // nonisolated(unsafe): only mutated on the main actor; deinit needs to read
    // them for teardown, which is safe because the object is uniquely referenced.
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private nonisolated(unsafe) var hotkeyRef: EventHotKeyRef?
    private let hotkeyID = EventHotKeyID(signature: OSType(0x4D_50_43_54), id: 1) // MPCT

    deinit {
        // The Carbon handler holds an unretained pointer to self; tear both
        // registrations down so it can never fire against a freed instance.
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus {
        unregister()

        if eventHandler == nil {
            // MacPict only acts on the key press; the release carries no meaning.
            var eventTypes = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            ]
            let userData = Unmanaged.passUnretained(self).toOpaque()
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                Self.carbonEventHandler,
                eventTypes.count,
                &eventTypes,
                userData,
                &eventHandler
            )
            guard installStatus == noErr else {
                AppLogger.hotkey.error("Carbon event handler installation failed with status \(installStatus)")
                return record(.failed(installStatus))
            }
        }

        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        guard registerStatus == noErr else {
            hotkeyRef = nil
            AppLogger.hotkey.error(
                "Registration of \(shortcut.displayString, privacy: .public) failed with status \(registerStatus)"
            )
            return record(.failed(registerStatus))
        }
        AppLogger.hotkey.info("Global hotkey \(shortcut.displayString, privacy: .public) registered")
        return record(.registered)
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            AppLogger.hotkey.info("Global hotkey unregistered")
        }
        hotkeyRef = nil
        status = nil
    }

    private func record(_ newStatus: HotkeyRegistrationStatus) -> HotkeyRegistrationStatus {
        status = newStatus
        return newStatus
    }

    private func handle(identifier: UInt32) -> OSStatus {
        guard identifier == hotkeyID.id else { return OSStatus(eventNotHandledErr) }
        onTrigger?()
        return noErr
    }

    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var receivedID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard parameterStatus == noErr else { return OSStatus(eventNotHandledErr) }
        guard GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        let identifier = receivedID.id
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        // Carbon delivers hot key events on the main run loop.
        return MainActor.assumeIsolated {
            manager.handle(identifier: identifier)
        }
    }
}
