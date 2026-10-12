import AppKit
import Carbon

/// While the history panel is visible, register Carbon hotkeys for ⌘V and Return.
///
/// A `.nonactivatingPanel` keeps the destination app frontmost; without a global
/// grab those keys would go to the dialog (Return might submit it). Carbon hotkeys
/// work system-wide and suppress delivery to the destination while registered.
@MainActor
final class PanelPasteHotKeys {
    static let shared = PanelPasteHotKeys()

    fileprivate static let signature: OSType = 0x4853_4351 // "HSCQ"
    fileprivate static let idPastePlain: UInt32 = 10
    fileprivate static let idPasteFormatted: UInt32 = 11

    private var plainRef: EventHotKeyRef?
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
        switch id.id {
        case Self.idPastePlain:
            NotificationCenter.default.post(name: .hisCopyPanelPastePlain, object: nil)
        case Self.idPasteFormatted:
            NotificationCenter.default.post(name: .hisCopyPanelPasteFormatted, object: nil)
        default:
            break
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
            GetApplicationEventTarget(),
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
        var plainID = EventHotKeyID(signature: Self.signature, id: Self.idPastePlain)
        var formattedID = EventHotKeyID(signature: Self.signature, id: Self.idPasteFormatted)
        var plain: EventHotKeyRef?
        var formatted: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey),
            plainID,
            GetApplicationEventTarget(),
            0,
            &plain
        )
        RegisterEventHotKey(
            UInt32(kVK_Return),
            0,
            formattedID,
            GetApplicationEventTarget(),
            0,
            &formatted
        )
        plainRef = plain
        formattedRef = formatted
    }

    private func unregister() {
        if let plainRef {
            UnregisterEventHotKey(plainRef)
            self.plainRef = nil
        }
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
    Task { @MainActor in
        obj.handleHotKey(id: hotKeyID)
    }
    return noErr
}
