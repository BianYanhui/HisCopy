import AppKit
import Carbon
import Combine
import os.log

private let hotKeyLog = Logger(subsystem: "com.bianyanhui.HisCopy", category: "HotKey")

/// Global open/close hotkey via Carbon `RegisterEventHotKey`.
///
/// v0.8.3 — why v0.8.2 still failed:
/// The ignore-until-Released / chord-poll gate was not the live failure mode.
/// After the docked berth calls `makeKeyAndOrderFront`, subsequent hotkey
/// `Pressed` events often never reach a handler installed on
/// `GetApplicationEventTarget()` (menu-bar / nonactivating-panel quirk).
/// Clearing `ignorePressedUntilChordRelease` then did nothing: there was no
/// Pressed to unblock. Pulse registers on `GetEventDispatcherTarget()` and
/// fires on every Pressed with no Released gate — that is what we do now.
///
/// Duplicate Pressed (menu keyEquivalent races, sticky keys) is filtered with
/// a 300ms timestamp debounce, not a Released latch.
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    private static let signature: OSType = 0x4853_4350 // "HSCP"
    private static let hotKeyID: UInt32 = 1
    private static let defaultsKeyCode = "globalHotKeyKeyCode"
    private static let defaultsModifiers = "globalHotKeyCarbonModifiers"
    /// Ignore a second Pressed this soon after a handled one (not a Released latch).
    private static let debounceInterval: TimeInterval = 0.30

    @Published private(set) var shortcut: HotKeyShortcut
    /// 非空表示当前快捷键未能注册（多为冲突）。
    @Published private(set) var registrationFailureMessage: String?

    var onHotKeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var eventHandlerInstalled = false
    private var lastHandledPressedAt: Date?

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
        lastHandledPressedAt = nil
    }

    /// Update shortcut、写入 UserDefaults，并立即重新注册。
    func updateShortcut(_ newValue: HotKeyShortcut) {
        shortcut = newValue
        persist(newValue)
        registerCurrentShortcut()
    }

    func resetToDefault() {
        updateShortcut(.default)
    }

    /// Re-bind with the window server after panel open/close. Heals a dead
    /// `EventHotKeyRef` if macOS dropped it when the nonactivating berth keyed.
    func reregister() {
        registerCurrentShortcut()
    }

    private func persist(_ value: HotKeyShortcut) {
        let defaults = UserDefaults.standard
        defaults.set(Int(value.keyCode), forKey: Self.defaultsKeyCode)
        defaults.set(Int(value.carbonModifiers), forKey: Self.defaultsModifiers)
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

        // Pressed only — same as Pulse. No Released latch.
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        // GetEventDispatcherTarget — Pulse / reliable for accessory + nonactivating panels.
        // GetApplicationEventTarget stopped receiving Pressed after the berth became key.
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventCallback,
            Int(specs.count),
            &specs,
            userData,
            &handlerRef
        )
        if status == noErr {
            eventHandlerInstalled = true
        } else {
            registrationFailureMessage = "无法安装全局热键事件处理（错误码 \(status)）。"
            hotKeyLog.error("InstallEventHandler failed: \(status, privacy: .public)")
        }
    }

    fileprivate func handleCarbonHotKey(kind: UInt32, id: EventHotKeyID) {
        guard id.signature == Self.signature, id.id == Self.hotKeyID else { return }
        guard kind == UInt32(kEventHotKeyPressed) else { return }

        let now = Date()
        if let last = lastHandledPressedAt, now.timeIntervalSince(last) < Self.debounceInterval {
            hotKeyLog.debug("Pressed debounced (\(now.timeIntervalSince(last), format: .fixed(precision: 3))s)")
            return
        }
        lastHandledPressedAt = now
        hotKeyLog.info("Pressed → toggle (\(self.shortcut.displayString, privacy: .public))")
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
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRef = ref
            registrationFailureMessage = nil
            hotKeyLog.info("Registered \(self.shortcut.displayString, privacy: .public)")
        } else {
            hotKeyRef = nil
            let name = shortcut.displayString
            registrationFailureMessage =
                "快捷键 \(name) 注册失败（可能与其他应用冲突，错误码 \(status)）。请在设置中更换。"
            hotKeyLog.error("RegisterEventHotKey failed: \(status, privacy: .public)")
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

/// Carbon C callback. The dispatcher target invokes this on the main run loop
/// (same assumption Pulse makes) — call the actor directly, no `Task` hop.
private func hotKeyEventCallback(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let kind = GetEventKind(theEvent)

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
    MainActor.assumeIsolated {
        manager.handleCarbonHotKey(kind: kind, id: hotKeyID)
    }
    return noErr
}
