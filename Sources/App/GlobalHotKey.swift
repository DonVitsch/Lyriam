import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon so it fires no matter which app is
/// frontmost — necessary because this is an accessory (no-Dock) app that never
/// becomes the active app, so the standard ⌘, menu shortcut never reaches it.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_Comma`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey`.
    init(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping () -> Void) {
        self.onPressed = onPressed

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onPressed() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: 0x4C594953 /* 'LYIS' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
