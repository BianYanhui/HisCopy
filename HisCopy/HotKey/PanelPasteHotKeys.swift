import AppKit
import Carbon

/// While the history panel is visible, Carbon-register **Return** so Enter pastes
/// even when a `.nonactivatingPanel` keeps another app frontmost.
///
/// Never register ⌘V here — it shares a key code with the default open shortcut
/// ⇧⌘V and corrupts that registration on current macOS. ⌘V paste uses
/// `PanelPasteShortcutGate`'s local monitor when the (undocked) panel is key,
/// or the on-panel button.
@MainActor
final class PanelPasteHotKeys {
    static let shared = PanelPasteHotKeys()

    fileprivate static let signature: OSType = 0x4853_4351 // "HSCQ"
    fileprivate static let idPasteFormatted: UInt32 = 11

    private var formattedRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    fileprivate var enabled = false

    private init() {}

    func start() {
        installHandlerIfNeeded()
        register()
        enabled = false
    }

    func setArmed(_ armed: Bool) {
        enabled = armed
    }

    func stop() {
        enabled = false
        unregister()
    }

    fileprivate func handleHotKey(id: EventHotKeyID) {
        guard enabled, id.signature == Self.signature else { return }
        if id.id == Self.idPasteFormatted {
            NotificationCenter.default.post(name: .hisCopyPanelPasteFormatted, object: nil)
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            panelPasteHotKeyCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        handlerInstalled = (status == noErr)
        if !handlerInstalled { handlerRef = nil }
    }

    private func register() {
        unregister()
        var formattedID = EventHotKeyID(signature: Self.signature, id: Self.idPasteFormatted)
        var formatted: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_Return),
            0,
            formattedID,
            GetEventDispatcherTarget(),
            0,
            &formatted
        )
        formattedRef = formatted
    }

    private func unregister() {
        if let formattedRef {
            UnregisterEventHotKey(formattedRef)
            self.formattedRef = nil
        }
    }
}

private func panelPasteHotKeyCallback(
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
    let obj = Unmanaged<PanelPasteHotKeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { obj.handleHotKey(id: hotKeyID) }
    return noErr
}
