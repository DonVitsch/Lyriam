import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon so it fires no matter which app is
/// frontmost — necessary because this is an accessory (no-Dock) app that never
/// becomes the active app, so the standard ⌘, menu shortcut never reaches it.
final class GlobalHotKey {
    private static var nextIdentifier: UInt32 = 1
    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_Comma`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey`.
    init(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
                pressed.signature == 0x4C594953, pressed.id == me.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { me.onPressed() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: 0x4C594953 /* 'LYIS' */, id: identifier)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
