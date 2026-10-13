import AppKit
import ApplicationServices
import Carbon
import Combine

/// Global open/close hotkey for the history panel.
///
/// **Architecture (v0.8.7)**
/// 1. **Primary:** session `CGEvent` tap when Accessibility is trusted (reliable
///    after panel show/hide; what works on the user’s Mac).
/// 2. **Secondary:** `NSEvent` local + global keyDown monitors (local covers a
///    keyed undocked panel; global needs AX like the tap).
/// 3. **Optional backup:** Carbon `RegisterEventHotKey` — never paired with a
///    paste ⌘V hotkey; docked panel never becomes key (see DockedHistoryPanel).
///
/// Accessibility is required for a reliable shortcut. Without it, Carbon may
/// work once then go silent; Settings prompts the user to authorize this binary.
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    private static let carbonSignature: OSType = 0x4853_4350 // "HSCP"
    private static let carbonHotKeyID: UInt32 = 1
    private static let defaultsKeyCode = "globalHotKeyKeyCode"
    private static let defaultsModifiers = "globalHotKeyCarbonModifiers"
    private static let debounceInterval: TimeInterval = 0.30

    @Published private(set) var shortcut: HotKeyShortcut
    @Published private(set) var registrationFailureMessage: String?
    /// True when the CGEvent tap is installed and enabled.
    @Published private(set) var eventTapActive = false

    var onHotKeyPressed: (() -> Void)?

    private var carbonRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var carbonHandlerInstalled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastHandledAt: Date?
    private var becomeActiveObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKeyCode) != nil {
            shortcut = HotKeyShortcut(
                keyCode: UInt32(defaults.integer(forKey: Self.defaultsKeyCode)),
                carbonModifiers: UInt32(defaults.integer(forKey: Self.defaultsModifiers))
            )
        } else {
            shortcut = .default
            persist(shortcut)
        }
    }

    // MARK: - Lifecycle

    func start() {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        HotKeyTrace.line("start v\(ver) (\(build)) shortcut=\(shortcut.displayString)")

        installCarbonHandlerIfNeeded()
        registerCarbonBackup()
        installEventMonitors()
        refreshAccessibilityDependentPaths(prompt: false)

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccessibilityDependentPaths(prompt: false)
            }
        }
    }

    func stop() {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
        removeEventTap()
        removeEventMonitors()
        unregisterCarbon()
        lastHandledAt = nil
        eventTapActive = false
    }

    func updateShortcut(_ newValue: HotKeyShortcut) {
        shortcut = newValue
        persist(newValue)
        HotKeyTrace.line("shortcut → \(newValue.displayString)")
        unregisterCarbon()
        registerCarbonBackup()
        // Monitors / tap read `shortcut` live.
    }

    func resetToDefault() {
        updateShortcut(.default)
    }

    /// Call after TCC changes (Settings “重新检查” / prompt).
    func refreshAccessibilityDependentPaths(prompt: Bool) {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary)

        if trusted {
            installEventTapIfNeeded()
            if globalMonitor == nil { installEventMonitors() }
            HotKeyTrace.line("AX trusted; tapActive=\(eventTapActive)")
        } else {
            removeEventTap()
            HotKeyTrace.important(
                "辅助功能未授权：全局快捷键不可靠。请在系统设置中为本进程 HisCopy 打开辅助功能（删除陈旧条目后重新添加当前 .app）。"
            )
        }
    }

    // MARK: - Fire

    @discardableResult
    func handleChord(source: String) -> Bool {
        let now = Date()
        if let last = lastHandledAt, now.timeIntervalSince(last) < Self.debounceInterval {
            HotKeyTrace.line("debounce skip source=\(source)")
            return false
        }
        lastHandledAt = now
        HotKeyTrace.line("FIRE source=\(source)")
        onHotKeyPressed?()
        return true
    }

    func eventMatchesShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return mods == shortcut.cocoaModifierFlags
    }

    // MARK: - CGEvent tap (primary)

    private func installEventTapIfNeeded() {
        if eventTap != nil {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            eventTapActive = true
            return
        }
        guard AXIsProcessTrusted() else {
            eventTapActive = false
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotKeyCGEventCallback,
            userInfo: userInfo
        ) else {
            eventTapActive = false
            HotKeyTrace.important("CGEvent tapCreate failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        eventTapActive = true
        HotKeyTrace.important("CGEvent tap installed (primary hotkey path)")
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
        }
        eventTap = nil
        eventTapSource = nil
        eventTapActive = false
    }

    fileprivate func handleCGKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.keyCode else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }

        var mods: NSEvent.ModifierFlags = []
        let flags = event.flags
        if flags.contains(.maskCommand) { mods.insert(.command) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskControl) { mods.insert(.control) }
        guard mods == shortcut.cocoaModifierFlags else { return false }
        return handleChord(source: "cgevent")
    }

    fileprivate func reenableTapAfterSystemDisable() {
        HotKeyTrace.line("CGEvent tap re-enable after system disable")
        installEventTapIfNeeded()
    }

    // MARK: - NSEvent monitors

    private func installEventMonitors() {
        removeEventMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard self.eventMatchesShortcut(event) else { return event }
                _ = self.handleChord(source: "local")
                return nil
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.eventMatchesShortcut(event) else { return }
                _ = self.handleChord(source: "global")
            }
        }
        HotKeyTrace.line("monitors local=\(localMonitor != nil) global=\(globalMonitor != nil)")
    }

    private func removeEventMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    // MARK: - Carbon backup

    private func persist(_ value: HotKeyShortcut) {
        UserDefaults.standard.set(Int(value.keyCode), forKey: Self.defaultsKeyCode)
        UserDefaults.standard.set(Int(value.carbonModifiers), forKey: Self.defaultsModifiers)
    }

    private func installCarbonHandlerIfNeeded() {
        guard !carbonHandlerInstalled else { return }
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyCarbonCallback,
            1,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonHandlerRef
        )
        carbonHandlerInstalled = (status == noErr)
        HotKeyTrace.line("carbon handler status=\(status)")
    }

    fileprivate func handleCarbonPressed(id: EventHotKeyID) {
        guard id.signature == Self.carbonSignature, id.id == Self.carbonHotKeyID else { return }
        _ = handleChord(source: "carbon")
    }

    private func registerCarbonBackup() {
        unregisterCarbon()
        registrationFailureMessage = nil
        guard shortcut.isValid else {
            registrationFailureMessage = "快捷键无效：请至少包含一个修饰键（⌘ / ⌥ / ⌃ / ⇧）。"
            return
        }
        var id = EventHotKeyID(signature: Self.carbonSignature, id: Self.carbonHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            carbonRef = ref
            HotKeyTrace.line("carbon backup registered")
        } else {
            carbonRef = nil
            registrationFailureMessage =
                "Carbon 备份注册失败（\(status)）。请确保已授权辅助功能以使用主路径。"
            HotKeyTrace.line("carbon backup FAIL status=\(status)")
        }
    }

    private func unregisterCarbon() {
        if let carbonRef {
            UnregisterEventHotKey(carbonRef)
            self.carbonRef = nil
        }
    }
}

// MARK: - C callbacks

private func hotKeyCarbonCallback(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent, let userData else { return OSStatus(eventNotHandledErr) }
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
    guard err == noErr else { return err }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handleCarbonPressed(id: hotKeyID) }
    return noErr
}

private func hotKeyCGEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { manager.reenableTapAfterSystemDisable() }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    var handled = false
    let run = {
        MainActor.assumeIsolated { handled = manager.handleCGKeyDown(event) }
    }
    if Thread.isMainThread {
        run()
    } else {
        DispatchQueue.main.sync(execute: run)
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}
