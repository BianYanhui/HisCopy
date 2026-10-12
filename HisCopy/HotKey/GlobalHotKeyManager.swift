import AppKit
import Carbon
import Combine

/// 使用 Carbon `RegisterEventHotKey` 注册全局热键（零第三方依赖，思路接近 Maccy）。
/// 仅用于呼出/隐藏面板，不模拟按键，因此通常不需要辅助功能（Accessibility）权限。
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    private static let signature: OSType = 0x4853_4350 // "HSCP"
    private static let hotKeyID: UInt32 = 1
    private static let defaultsKeyCode = "globalHotKeyKeyCode"
    private static let defaultsModifiers = "globalHotKeyCarbonModifiers"

    @Published private(set) var shortcut: HotKeyShortcut
    /// 非空表示当前快捷键未能注册（多为冲突）。
    @Published private(set) var registrationFailureMessage: String?

    var onHotKeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var eventHandlerInstalled = false

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Self.defaultsKeyCode))
            let mods = UInt32(defaults.integer(forKey: Self.defaultsModifiers))
            shortcut = HotKeyShortcut(keyCode: code, carbonModifiers: mods)
        } else {
            shortcut = .default
            persist(shortcut)
        }
    }

    func start() {
        installEventHandlerIfNeeded()
        registerCurrentShortcut()
    }

    func stop() {
        unregister()
    }

    /// 更新快捷键、写入 UserDefaults，并立即重新注册。
    func updateShortcut(_ newValue: HotKeyShortcut) {
        shortcut = newValue
        persist(newValue)
        registerCurrentShortcut()
    }

    func resetToDefault() {
        updateShortcut(.default)
    }

    private func persist(_ value: HotKeyShortcut) {
        let defaults = UserDefaults.standard
        defaults.set(Int(value.keyCode), forKey: Self.defaultsKeyCode)
        defaults.set(Int(value.carbonModifiers), forKey: Self.defaultsModifiers)
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            userData,
            &handlerRef
        )
        if status == noErr {
            eventHandlerInstalled = true
        } else {
            registrationFailureMessage = "无法安装全局热键事件处理（错误码 \(status)）。"
        }
    }

    fileprivate func handleCarbonHotKey(id: EventHotKeyID) {
        guard id.signature == Self.signature, id.id == Self.hotKeyID else { return }
        onHotKeyPressed?()
    }

    private func registerCurrentShortcut() {
        unregister()
        registrationFailureMessage = nil

        guard shortcut.isValid else {
            registrationFailureMessage = "快捷键无效：请至少包含一个修饰键（⌘ / ⌥ / ⌃ / ⇧）。"
            return
        }

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRef = ref
            registrationFailureMessage = nil
        } else {
            hotKeyRef = nil
            let name = shortcut.displayString
            registrationFailureMessage =
                "快捷键 \(name) 注册失败（可能与其他应用冲突，错误码 \(status)）。请在设置中更换。"
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

/// Carbon C 回调：必须是全局 `@convention(c)` 函数，不能捕获上下文。
private func hotKeyEventCallback(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard err == noErr else {
        return err
    }

    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.handleCarbonHotKey(id: hotKeyID)
    }
    return noErr
}
