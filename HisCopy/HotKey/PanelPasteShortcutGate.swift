import AppKit
import Combine

extension Notification.Name {
    /// Armed panel: paste plain text for current selection (⌘V).
    static let hisCopyPanelPastePlain = Notification.Name("HisCopyPanelPastePlain")
    /// Armed panel: paste formatted for current selection (Return).
    static let hisCopyPanelPasteFormatted = Notification.Name("HisCopyPanelPasteFormatted")
}

/// Prevents the open hotkey chord from firing panel paste, then routes ⌘V / Return
/// via local monitor (reliable for `.nonactivatingPanel` where SwiftUI
/// `.keyboardShortcut` may not run because HisCopy is not the active app).
///
/// **Unlock (arm) only enables paste routing; never hides the panel.**
@MainActor
final class PanelPasteShortcutGate: ObservableObject {
    static let shared = PanelPasteShortcutGate()

    @Published private(set) var isArmed = true

    private var monitor: Any?
    private var pollWorkItem: DispatchWorkItem?
    private var armingStartedAt: Date?

    private static let pollInterval: TimeInterval = 0.05
    private static let forceArmAfter: TimeInterval = 2.0
    private static let keyCodeV: CGKeyCode = 0x09
    private static let keyCodeReturn: CGKeyCode = 0x24
    private static let keyCodeKeypadEnter: CGKeyCode = 0x4C

    private init() {}

    /// Panel about to show: lock until open chord fully released; keep monitor for paste.
    func beginArmingAfterPanelOpen() {
        tearDownMonitorAndPoll()
        isArmed = false
        armingStartedAt = Date()
        PanelPasteHotKeys.shared.start()
        PanelPasteHotKeys.shared.setArmed(false)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitorEvent(event)
        }

        if Self.isOpenHotkeyChordFullyReleased() {
            armKeepingMonitor()
            return
        }
        schedulePoll()
    }

    /// Panel hidden: reset and remove monitor.
    func reset() {
        tearDownMonitorAndPoll()
        isArmed = true
        armingStartedAt = nil
        PanelPasteHotKeys.shared.stop()
    }

    // MARK: - Private

    private func handleMonitorEvent(_ event: NSEvent) -> NSEvent? {
        if Self.isPanelPasteShortcutKeyDown(event) {
            if !isArmed {
                tryArmFromCurrentKeyState()
                return nil
            }
            // Armed: handle paste here (do not rely on SwiftUI keyboardShortcut).
            if event.keyCode == Self.keyCodeV {
                NotificationCenter.default.post(name: .hisCopyPanelPastePlain, object: nil)
            } else {
                NotificationCenter.default.post(name: .hisCopyPanelPasteFormatted, object: nil)
            }
            return nil
        }

        if event.type == .flagsChanged || event.type == .keyUp {
            tryArmFromCurrentKeyState()
        }
        return event
    }

    private func schedulePoll() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isArmed else { return }
            self.tryArmFromCurrentKeyState()
            if !self.isArmed {
                self.schedulePoll()
            }
        }
        pollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval, execute: work)
    }

    private func tryArmFromCurrentKeyState() {
        guard !isArmed else { return }
        if Self.isOpenHotkeyChordFullyReleased() {
            armKeepingMonitor()
            return
        }
        if let started = armingStartedAt, Date().timeIntervalSince(started) >= Self.forceArmAfter {
            armKeepingMonitor()
        }
    }

    /// Unlock paste; **keep** the key monitor so ⌘V / Return work on a nonactivating panel.
    private func armKeepingMonitor() {
        guard !isArmed else { return }
        isArmed = true
        armingStartedAt = nil
        pollWorkItem?.cancel()
        pollWorkItem = nil
        PanelPasteHotKeys.shared.setArmed(true)
        // Keep `monitor` installed until `reset()`.
    }

    private func tearDownMonitorAndPoll() {
        pollWorkItem?.cancel()
        pollWorkItem = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func isOpenHotkeyChordFullyReleased() -> Bool {
        let mods = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        if !mods.isEmpty { return false }
        if CGEventSource.keyState(.combinedSessionState, key: keyCodeV) { return false }
        return true
    }

    private static func isPanelPasteShortcutKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == keyCodeV, mods == .command {
            return true
        }
        if (event.keyCode == keyCodeReturn || event.keyCode == keyCodeKeypadEnter), mods.isEmpty {
            return true
        }
        return false
    }
}
