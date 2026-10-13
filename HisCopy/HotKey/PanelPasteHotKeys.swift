import AppKit
import Carbon

/// While the history panel is visible, register a Carbon hotkey for **Return**
/// so Enter pastes even when a `.nonactivatingPanel` is key and the destination
/// app is still frontmost.
///
/// v0.8.5: **Do not** RegisterEventHotKey ⌘V here. The open shortcut defaults to
/// ⇧⌘V (same key code). Registering ⌘V alongside ⇧⌘V corrupts the open-hotkey
/// registration on current macOS — after the panel closes, Pressed never fires
/// again (user hotkey.log on v0.8.4). ⌘V paste is handled by
/// `PanelPasteShortcutGate`'s local monitor (panel is key while open).
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
        HotKeyTrace.line("pasteCarbon start (Return only; no ⌘V)")
    }

    func setArmed(_ armed: Bool) {
        enabled = armed
    }

    func stop() {
        enabled = false
        unregister()
        HotKeyTrace.line("pasteCarbon stop")
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
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            panelPasteHotKeyCallback,
            1,
            &spec,
            userData,
            &handlerRef
        )
        handlerInstalled = (status == noErr)
        if !handlerInstalled {
            handlerRef = nil
        }
    }

    private func register() {
        unregister()
        var formattedID = EventHotKeyID(signature: Self.signature, id: Self.idPasteFormatted)
        var formatted: EventHotKeyRef?
        // Return only — never ⌘V (conflicts with open hotkey ⇧⌘V).
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
    let obj = Unmanaged<PanelPasteHotKeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        obj.handleHotKey(id: hotKeyID)
    }
    return noErr
}
