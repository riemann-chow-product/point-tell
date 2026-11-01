import Cocoa
import Carbon

private var gHotkeyHandler: (() -> Void)?

private func pointTellHotkeyCallback(_ nextHandler: EventHandlerCallRef?,
                                     _ event: EventRef?,
                                     _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        gHotkeyHandler?()
    }
    return noErr
}

/// 用 Carbon 的 RegisterEventHotKey 注册全局热键。
/// 相比 CGEventTap，它不需要「输入监控」权限，只依赖应用自身的事件循环。
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) {
        unregister()
        gHotkeyHandler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            pointTellHotkeyCallback,
                            1,
                            &eventType,
                            nil,
                            &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50544C54), id: 1) // 'PTLT'
        let status = RegisterEventHotKey(keyCode,
                                         carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        if status != noErr {
            PTLog.write("hotkey register failed: \(status)")
        } else {
            PTLog.write("hotkey registered: \(hotkeyDisplayString(keyCode: keyCode, carbonModifiers: carbonModifiers))")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
