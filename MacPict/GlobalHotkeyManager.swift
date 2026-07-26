import Carbon.HIToolbox
import Foundation

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case registered(String)
    case conflict(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .notRegistered: "Not registered"
        case let .registered(shortcut): "Registered: \(shortcut)"
        case let .conflict(shortcut): "Shortcut conflict: \(shortcut) is already in use"
        case let .failed(detail): "Registration failed: \(detail)"
        }
    }

    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    var onTrigger: (() -> Void)?
    @Published private(set) var status: HotkeyRegistrationStatus = .notRegistered
    /// The shortcut currently registered with Carbon, or nil when none is.
    ///
    /// This doubles as the shortcut a failed change reverts to, because "last known good" and
    /// "live right now" are the same fact: every successful registration replaces the previous
    /// one, and every failure or teardown leaves nothing registered. Storing it once means the
    /// revert target can never disagree with what callers are told is active.
    @Published private(set) var activeShortcut: HotkeyShortcut?

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

    /// Intentional divergence from MacDictate: its `register(_:)` unregisters first and, when the
    /// new shortcut fails, leaves the user with no working hotkey at all. Now that the shortcut is
    /// picked from a list and can land on a combination another app already owns, that is a trap.
    /// So a failed attempt is reported for the shortcut the user chose — they must see that their
    /// choice did not take — and the last shortcut that registered successfully is then silently
    /// restored, so capture keeps working. `status` describes the attempted shortcut's outcome;
    /// `activeShortcut` describes what is actually live afterwards.
    @discardableResult
    func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus {
        // Read before attempting: the attempt releases the current registration.
        let previous = activeShortcut
        let outcome = attemptRegistration(of: shortcut)
        if !outcome.isRegistered, let previous, previous != shortcut {
            let reverted = attemptRegistration(of: previous)
            if reverted.isRegistered {
                AppLogger.hotkey.info("Reverted to \(previous.displayString, privacy: .public) after a failed change")
            }
        }
        status = outcome
        return outcome
    }

    func unregister() {
        releaseHotkey()
        // Deliberate teardown: nothing should resurrect a shortcut after this point.
        status = .notRegistered
    }

    /// Registers `shortcut`, updates `activeShortcut` to match live Carbon state, and reports the
    /// outcome without touching `status`, so `register(_:)` alone decides what the user is told
    /// and what is restored on failure.
    private func attemptRegistration(of shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus {
        releaseHotkey()

        let installStatus = installEventHandlerIfNeeded()
        guard installStatus == noErr else {
            AppLogger.hotkey.error("Carbon event handler installation failed with status \(installStatus)")
            return .failed("Carbon event handler error \(installStatus)")
        }

        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        switch registerStatus {
        case noErr:
            activeShortcut = shortcut
            AppLogger.hotkey.info("Global hotkey \(shortcut.displayString, privacy: .public) registered")
            return .registered(shortcut.displayString)
        case OSStatus(eventHotKeyExistsErr):
            hotkeyRef = nil
            AppLogger.hotkey.error(
                "\(shortcut.displayString, privacy: .public) is already in use by another application"
            )
            return .conflict(shortcut.displayString)
        default:
            hotkeyRef = nil
            AppLogger.hotkey.error(
                "Registration of \(shortcut.displayString, privacy: .public) failed with status \(registerStatus)"
            )
            return .failed("Carbon error \(registerStatus)")
        }
    }

    /// Drops any live registration. The single place `activeShortcut` is cleared, so it cannot
    /// claim a shortcut is active after the Carbon registration behind it is gone.
    private func releaseHotkey() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            AppLogger.hotkey.info("Global hotkey unregistered")
        }
        hotkeyRef = nil
        activeShortcut = nil
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        // MacPict only acts on the key press; the release carries no meaning.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonEventHandler,
            eventTypes.count,
            &eventTypes,
            userData,
            &eventHandler
        )
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
