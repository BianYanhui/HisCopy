import AppKit
import Combine

/// 防止「⇧⌘V 呼出面板」与面板内「⌘V 粘贴纯文本」抢同一物理按键序列。
///
/// Carbon 热键在 keyDown 时已打开面板；若此时仍按着 ⌘/V（常见：先松 ⇧），
/// 面板成为 key window 后会把后续 key-repeat 或残余 ⌘V 当成粘贴快捷键。
/// 本闸门在打开后禁用面板粘贴快捷键，直到修饰键与 V 全部松开。
///
/// **解锁（arm）只恢复面板内 ⌘V/回车，绝不隐藏面板。** 关面板由再次热键、
/// Esc、粘贴成功、点外部等路径负责。
@MainActor
final class PanelPasteShortcutGate: ObservableObject {
    static let shared = PanelPasteShortcutGate()

    @Published private(set) var isArmed = true

    private var monitor: Any?
    private var pollWorkItem: DispatchWorkItem?
    private var armingStartedAt: Date?

    /// 轮询间隔（监控器漏事件时的兜底）。
    private static let pollInterval: TimeInterval = 0.05
    /// 极端情况下（keyState 异常）最长等待后强制解锁。
    private static let forceArmAfter: TimeInterval = 2.0
    private static let keyCodeV: CGKeyCode = 0x09 // kVK_ANSI_V
    private static let keyCodeReturn: CGKeyCode = 0x24
    private static let keyCodeKeypadEnter: CGKeyCode = 0x4C

    private init() {}

    /// 面板即将显示时调用：先上锁，等呼出和弦松开后再开锁（仅开锁，不关面板）。
    func beginArmingAfterPanelOpen() {
        tearDownMonitorAndPoll()
        isArmed = false
        armingStartedAt = Date()

        if Self.isOpenHotkeyChordFullyReleased() {
            isArmed = true
            armingStartedAt = nil
            return
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitorEvent(event)
        }

        schedulePoll()
    }

    /// 面板隐藏时复位（下次打开再重新闸门）。不由解锁路径调用。
    func reset() {
        tearDownMonitorAndPoll()
        isArmed = true
        armingStartedAt = nil
    }

    // MARK: - Private

    private func handleMonitorEvent(_ event: NSEvent) -> NSEvent? {
        if !isArmed, Self.isPanelPasteShortcutKeyDown(event) {
            // 吞掉竞态中的 ⌘V / 回车，避免落入 `.keyboardShortcut`。
            tryArmFromCurrentKeyState()
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
            arm()
            return
        }
        if let started = armingStartedAt, Date().timeIntervalSince(started) >= Self.forceArmAfter {
            arm()
        }
    }

    /// 仅恢复粘贴快捷键；禁止在此隐藏窗口或发关闭通知。
    private func arm() {
        guard !isArmed else { return }
        isArmed = true
        armingStartedAt = nil
        tearDownMonitorAndPoll()
    }

    private func tearDownMonitorAndPoll() {
        pollWorkItem?.cancel()
        pollWorkItem = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 呼出热键相关物理键均已松开：无 ⌘/⇧/⌥/⌃，且 V 未按下。
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
