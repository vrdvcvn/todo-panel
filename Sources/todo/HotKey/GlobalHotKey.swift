import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey.
///
/// Derived from `soffes/HotKey` (MIT) — https://github.com/soffes/HotKey —
/// which in turn was inspired by PTHotKey. Reduced to the two things `todo`
/// needs: register, and get told when pressed.
///
/// Why Carbon `RegisterEventHotKey` rather than an `CGEventTap`: an event tap
/// requires Accessibility permission, which means a system permission prompt
/// and a scary entry in System Settings. RegisterEventHotKey needs no
/// permission at all, and costs nothing while idle — the OS only wakes us
/// when the combination is actually pressed.
final class GlobalHotKey {
    /// Arbitrary signature identifying our hotkeys ('TODO').
    private static let signature: OSType = 0x544F_444F

    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var handlerInstalled = false

    private var identifier: UInt32 = 0
    private var reference: EventHotKeyRef?

    /// Returns `nil` when the combination is already claimed by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: GlobalHotKey.nextIdentifier)
        GlobalHotKey.nextIdentifier += 1
        GlobalHotKey.callbacks[hotKeyID.id] = action

        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr else {
            GlobalHotKey.callbacks.removeValue(forKey: hotKeyID.id)
            Diag.log("could not register hotkey id=\(hotKeyID.id) status=\(status)")
            return nil
        }

        GlobalHotKey.installHandlerIfNeeded()
        identifier = hotKeyID.id
        Diag.log("registered hotkey id=\(hotKeyID.id) keyCode=\(keyCode) modifiers=\(modifiers)")
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
        }
        reference = nil
        GlobalHotKey.callbacks.removeValue(forKey: identifier)
    }

    deinit {
        unregister()
    }

    // MARK: - Handler plumbing

    /// Entry point for the C callback below, which cannot reach private state.
    static func lookup(_ identifier: UInt32) -> (() -> Void)? {
        callbacks[identifier]
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            todoHotKeyEventHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )

        handlerInstalled = status == noErr
        if !handlerInstalled {
            Diag.log("InstallEventHandler failed with status \(status)")
        }
    }
}

/// C callback. Cannot capture context, so the hotkey is identified by the
/// `EventHotKeyID` carried on the event and dispatched through the lookup table.
///
/// Hotkey events are delivered on the main run loop, so touching `callbacks`
/// here needs no locking.
func todoHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr, hotKeyID.signature == 0x544F_444F else {
        return OSStatus(eventNotHandledErr)
    }

    guard let action = GlobalHotKeyCallback(for: hotKeyID.id) else {
        return OSStatus(eventNotHandledErr)
    }

    action()
    return noErr
}

/// Indirection so the C callback does not need access to private state.
func GlobalHotKeyCallback(for identifier: UInt32) -> (() -> Void)? {
    GlobalHotKey.lookup(identifier)
}

// MARK: - Key codes

enum KeyCode {
    static let q: UInt32 = 12
    static let tab: UInt32 = 48
    static let space: UInt32 = 49
    static let returnKey: UInt32 = 36
    static let escape: UInt32 = 53
    static let delete: UInt32 = 51 // backspace
    static let forwardDelete: UInt32 = 117
    static let arrowUp: UInt32 = 126
    static let arrowDown: UInt32 = 125
}