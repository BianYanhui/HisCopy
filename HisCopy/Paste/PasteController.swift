import AppKit
import ApplicationServices
import Combine

extension Notification.Name {
    /// 请求隐藏历史面板（粘贴后自动隐藏等）。
    static let hisCopyHideHistoryPanel = Notification.Name("HisCopyHideHistoryPanel")
    /// 粘贴前：隐藏面板并恢复先前前置应用焦点。
    static let hisCopyPrepareForPaste = Notification.Name("HisCopyPrepareForPaste")
}

/// 将条目写回剪贴板后，用 Accessibility / CGEvent 向前置 App 发送 ⌘V。
/// 无辅助功能权限时降级为仅写入剪贴板，并引导用户到系统设置授权。
@MainActor
final class PasteController: ObservableObject {
    static let shared = PasteController()

    static let autoHideKey = "HisCopy.autoHideAfterPaste"
    private static let didGuideAccessibilityKey = "HisCopy.didGuideAccessibility"

    /// 粘贴成功后是否自动隐藏历史面板（默认开启）。
    @Published var autoHideAfterPaste: Bool {
        didSet { UserDefaults.standard.set(autoHideAfterPaste, forKey: Self.autoHideKey) }
    }

    @Published private(set) var isAccessibilityTrusted: Bool

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoHideKey) == nil {
            defaults.set(true, forKey: Self.autoHideKey)
            autoHideAfterPaste = true
        } else {
            autoHideAfterPaste = defaults.bool(forKey: Self.autoHideKey)
        }
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// 刷新辅助功能信任状态（从设置返回时可调用）。
    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// 当前进程是否已获辅助功能授权。
    func checkAccessibilityTrusted(promptSystemDialog: Bool = false) -> Bool {
        if promptSystemDialog {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            isAccessibilityTrusted = trusted
            return trusted
        }
        let trusted = AXIsProcessTrusted()
        isAccessibilityTrusted = trusted
        return trusted
    }

    /// 点选历史后：内容已由调用方写入剪贴板；尝试 ⌘V 粘贴到前置应用。
    /// - Returns: `true` 表示已发出粘贴事件；`false` 表示仅写入剪贴板（无权限或失败）。
    @discardableResult
    func pasteToFrontmostApp(hidePanelIfConfigured: Bool = true) -> Bool {
        refreshAccessibilityStatus()

        guard isAccessibilityTrusted else {
            presentAccessibilityGuidance()
            if hidePanelIfConfigured && autoHideAfterPaste {
                NotificationCenter.default.post(name: .hisCopyHideHistoryPanel, object: nil)
            }
            return false
        }

        let shouldHide = hidePanelIfConfigured && autoHideAfterPaste
        NotificationCenter.default.post(
            name: .hisCopyPrepareForPaste,
            object: nil,
            userInfo: ["hidePanel": shouldHide]
        )

        // 稍候再发 ⌘V，等待前置 App 重新获得焦点。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.postCommandV()
        }
        return true
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings() {
        // Ventura+ System Settings；旧式 URL 作为回退。
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeV: CGKeyCode = 0x09 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func presentAccessibilityGuidance() {
        let alreadyGuided = UserDefaults.standard.bool(forKey: Self.didGuideAccessibilityKey)
        // 非首次：静默降级为仅剪贴板，避免反复弹窗打扰。
        guard !alreadyGuided else { return }

        UserDefaults.standard.set(true, forKey: Self.didGuideAccessibilityKey)
        // 顺带弹出系统授权对话框（若尚未授权）。
        _ = checkAccessibilityTrusted(promptSystemDialog: true)

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限才能一键粘贴"
        alert.informativeText = """
        已将所选内容写入剪贴板。若要自动向前置应用发送 ⌘V，请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 HisCopy。

        授权前可手动 ⌘V 完成粘贴。可随时在 HisCopy 设置中重新检查权限或打开系统设置。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "知道了")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
