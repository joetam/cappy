import Carbon.HIToolbox
import Foundation

final class GlobalShortcut {
    static let displayName = "⌃⌥C"
    static let enabledDefaultsKey = "desktopOverlay.globalShortcutEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    private let action: @MainActor () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    @MainActor
    init?(action: @escaping @MainActor () -> Void) {
        self.action = action

        let hotKeyID = EventHotKeyID(signature: 0x4341_5059, id: 1)  // CAPY
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else { return nil }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { shortcut.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
