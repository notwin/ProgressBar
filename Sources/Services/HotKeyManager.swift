// ═══════════════════════════════════════════════════════════════════
// 全局快捷键注册/注销（Carbon RegisterEventHotKey）
// ═══════════════════════════════════════════════════════════════════

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    private init() {}

    /// 返回 noErr 表示注册成功；非 noErr（例如 eventHotKeyExistsErr）表示冲突
    @discardableResult
    func register(config: HotKeyConfig, onTrigger: @escaping () -> Void) -> OSStatus {
        unregister()
        handler = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr {
                    DispatchQueue.main.async { mgr.handler?() }
                }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandlerRef
        )
        guard installStatus == noErr else {
            handler = nil
            return installStatus
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50524753), id: 1) // 'PRGS'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
            handler = nil
        }
        return status
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandlerRef {
            RemoveEventHandler(h)
            eventHandlerRef = nil
        }
        handler = nil
    }
}
