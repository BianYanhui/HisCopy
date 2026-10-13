import AppKit
import Carbon
import Combine

/// Open/close hotkey. v0.8.4: Carbon alone dies after a `.nonactivatingPanel`
/// becomes key (Pressed never arrives — Console silent). Dual path:
/// 1. Carbon `RegisterEventHotKey` on `GetEventDispatcherTarget` (still useful)
/// 2. `NSEvent` local + global keyDown monitors for the configured chord
/// 3. Session `CGEvent` tap when Accessibility is trusted (sees keys even when
///    Carbon is mute and when another app is frontmost)
///
/// All paths share one 300ms debounce. Pulse keeps its panel `canBecomeKey =
/// false`; HisCopy docked hotkey open likewise avoids `makeKey` (see
/// DockedPanelController) so Carbon is less likely to go silent.
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    private static let signature: OSType = 0x4853_4350 // "HSCP"
    private static let hotKeyID: UInt32 = 1
    private static let defaultsKeyCode = "globalHotKeyKeyCode"
    private static let defaultsModifiers = "globalHotKeyCarbonModifiers"
    private static let debounceInterval: TimeInterval = 0.30

    @Published private(set) var shortcut: HotKeyShortcut
    @Published private(set) var registrationFailureMessage: String?

    var onHotKeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var eventHandlerInstalled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastHandledAt: Date?
    private var axObserver: NSObjectProtocol?

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
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        HotKeyTrace.line("start v\(ver) (\(build)) shortcut=\(shortcut.displayString) log=\(HotKeyTrace.logFileURL.path)")
        installCarbonHandlerIfNeeded()
        registerCarbon()
        installEventMonitors()
        installEventTapIfPossible()
        axObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installEventTapIfPossible() }
        }
    }

    func stop() {
        unregisterCarbon()
        removeEventMonitors()
        removeEventTap()
        if let axObserver {
            NotificationCenter.default.removeObserver(axObserver)
            self.axObserver = nil
        }
        lastHandledAt = nil
    }

    func updateShortcut(_ newValue: HotKeyShortcut) {
        shortcut = newValue
        persist(newValue)
        HotKeyTrace.line("shortcut → \(newValue.displayString)")
        registerCarbon()
        // Monitors read `shortcut` live; tap callback does too.
    }

    func resetToDefault() {
        updateShortcut(.default)
    }

    /// After panel close — refresh Carbon + ensure tap/monitors still alive.
    func reregister() {
        HotKeyTrace.line("reregister")
        registerCarbon()
        if localMonitor == nil || globalMonitor == nil {
            installEventMonitors()
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            installEventTapIfPossible()
        }
    }

    // MARK: - Fire (all paths)

    /// - Parameter source: "carbon" / "local" / "global" / "cgevent"
    /// - Parameter swallow: whether the caller should eat the key event
    @discardableResult
    func handleChord(source: String) -> Bool {
        let now = Date()
        if let last = lastHandledAt, now.timeIntervalSince(last) < Self.debounceInterval {
            HotKeyTrace.line("debounce skip source=\(source)")
            return false
        }
        lastHandledAt = now
        HotKeyTrace.line("FIRE source=\(source) shortcut=\(shortcut.displayString)")
        onHotKeyPressed?()
        return true
    }

    func eventMatchesShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Ignore key-repeat; debounce also covers it.
        if event.isARepeat { return false }
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return mods == shortcut.cocoaModifierFlags
    }

    // MARK: - Carbon

    private func persist(_ value: HotKeyShortcut) {
        let defaults = UserDefaults.standard
        defaults.set(Int(value.keyCode), forKey: Self.defaultsKeyCode)
        defaults.set(Int(value.carbonModifiers), forKey: Self.defaultsModifiers)
    }

    private func installCarbonHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventCallback,
            Int(specs.count),
            &specs,
            userData,
            &handlerRef
        )
        eventHandlerInstalled = (status == noErr)
        HotKeyTrace.line("carbon InstallEventHandler status=\(status)")
        if status != noErr {
            registrationFailureMessage = "无法安装 Carbon 热键处理（错误码 \(status)）。仍将使用监听器回退。"
        }
    }

    fileprivate func handleCarbonPressed(id: EventHotKeyID) {
        guard id.signature == Self.signature, id.id == Self.hotKeyID else { return }
        handleChord(source: "carbon")
    }

    private func registerCarbon() {
        unregisterCarbon()
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
            HotKeyTrace.line("carbon RegisterEventHotKey OK")
        } else {
            hotKeyRef = nil
            registrationFailureMessage =
                "Carbon 快捷键 \(shortcut.displayString) 注册失败（\(status)）。已启用监听器回退。"
            HotKeyTrace.line("carbon RegisterEventHotKey FAIL status=\(status)")
        }
    }

    private func unregisterCarbon() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    // MARK: - NSEvent monitors (local + global)

    private func installEventMonitors() {
        removeEventMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard self.eventMatchesShortcut(event) else { return event }
                _ = self.handleChord(source: "local")
                return nil // swallow
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.eventMatchesShortcut(event) else { return }
                _ = self.handleChord(source: "global")
            }
        }

        HotKeyTrace.line(
            "monitors local=\(localMonitor != nil) global=\(globalMonitor != nil) (global needs Accessibility/Input Monitoring)"
        )
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

    // MARK: - CGEvent tap (AX)

    private func installEventTapIfPossible() {
        if eventTap != nil { return }
        // Session tap needs Accessibility (same entitlement paste already needs).
        guard AXIsProcessTrusted() else {
            HotKeyTrace.line("cgevent tap skipped — Accessibility not trusted")
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
            HotKeyTrace.line("cgevent tapCreate failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        HotKeyTrace.line("cgevent tap installed")
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
            self.eventTap = nil
            self.eventTapSource = nil
        }
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
}

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
    guard err == noErr else { return err }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleCarbonPressed(id: hotKeyID)
    }
    return noErr
}

private func hotKeyCGEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { manager.reregister() }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    var handled = false
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            handled = manager.handleCGKeyDown(event)
        }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                handled = manager.handleCGKeyDown(event)
            }
        }
    }
    // Swallow when we toggle so ⇧⌘V does not type into the front app.
    return handled ? nil : Unmanaged.passUnretained(event)
}
