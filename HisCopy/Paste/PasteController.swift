import AppKit
import ApplicationServices
import Combine

extension Notification.Name {
    static let hisCopyHideHistoryPanel = Notification.Name("HisCopyHideHistoryPanel")
    static let hisCopyPrepareForPaste = Notification.Name("HisCopyPrepareForPaste")
    static let hisCopyHistoryPanelDidOpen = Notification.Name("HisCopyHistoryPanelDidOpen")
    static let hisCopyPanelEscapeRequested = Notification.Name("HisCopyPanelEscapeRequested")
    static let hisCopyPanelMoveSelection = Notification.Name("HisCopyPanelMoveSelection")
}

/// Pastes via CGEvent ⌘V. Trust API can false-negative for ad-hoc builds (TCC tied to
/// code signature / cdhash; System Settings may still show an older HisCopy as ON).
/// We always attempt CGEvent; the published trust flag is informational + guidance only.
@MainActor
final class PasteController: ObservableObject {
    static let shared = PasteController()

    private static let frontmostPollInterval: TimeInterval = 0.02
    private static let frontmostMaxAttempts = 40
    private static let postFrontmostSettle: TimeInterval = 0.05
    private static let quickPasteDelay: TimeInterval = 0.05

    @Published private(set) var isAccessibilityTrusted: Bool
    /// Extra hint when Settings may show ON but this binary is not trusted (ad-hoc update).
    @Published private(set) var trustHint: String?

    private init() {
        isAccessibilityTrusted = Self.queryTrusted(prompt: false)
        trustHint = isAccessibilityTrusted ? nil : Self.staleTCCHint
    }

    /// Prefer `AXIsProcessTrustedWithOptions` — more reliable than bare `AXIsProcessTrusted`
    /// after the user toggles Privacy settings without relaunching.
    @discardableResult
    func refreshAccessibilityStatus(prompt: Bool = false) -> Bool {
        let trusted = Self.queryTrusted(prompt: prompt)
        isAccessibilityTrusted = trusted
        trustHint = trusted ? nil : Self.staleTCCHint
        if trusted {
            // CGEvent hotkey tap needs Accessibility; install when it flips on.
            GlobalHotKeyManager.shared.reregister()
        }
        return trusted
    }

    func checkAccessibilityTrusted(promptSystemDialog: Bool = false) -> Bool {
        refreshAccessibilityStatus(prompt: promptSystemDialog)
    }

    /// Content already on pasteboard. Hide panel and **always** synthesize ⌘V.
    /// Do not bail on a flaky trust bool — that was why v0.7.1 looked like a focus bug.
    @discardableResult
    func pasteToFrontmostAppAndClose() -> Bool {
        let reportedTrusted = refreshAccessibilityStatus(prompt: false)

        NotificationCenter.default.post(
            name: .hisCopyPrepareForPaste,
            object: nil,
            userInfo: ["hidePanel": true]
        )

        let targetPID = PasteFocusCoordinator.shared.targetPID
        if PasteFocusCoordinator.shared.destinationIsFrontmost || targetPID == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quickPasteDelay) { [weak self] in
                self?.postCommandV()
            }
        } else {
            _ = PasteFocusCoordinator.shared.restoreDestinationAppIfNeeded()
            waitUntilFrontmost(targetPID: targetPID, attempt: 0)
        }

        if !reportedTrusted {
            // After paste attempt: prompt so TCC can register *this* binary, then guide if still false.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if self.refreshAccessibilityStatus(prompt: true) { return }
                self.presentAccessibilityGuidance()
            }
        }
        return true
    }

    func openAccessibilitySettings() {
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

    private static let staleTCCHint = "系统列表里勾选的可能是旧版 HisCopy（ad-hoc 签名每次更新都会变）。请删除列表中所有 HisCopy，再重新添加当前应用并重启。"

    private static func queryTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        // WithOptions is the supported probe; also OR bare API in case of SDK quirks.
        let withOptions = AXIsProcessTrustedWithOptions(options)
        let bare = AXIsProcessTrusted()
        return withOptions || bare
    }

    private func waitUntilFrontmost(targetPID: pid_t?, attempt: Int) {
        if let targetPID {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.postFrontmostSettle) { [weak self] in
                    self?.postCommandV()
                }
                return
            }
            if attempt == 5 || attempt == 15 || attempt == 25 {
                _ = PasteFocusCoordinator.shared.restoreDestinationAppIfNeeded()
            }
        }
        if attempt >= Self.frontmostMaxAttempts {
            postCommandV()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frontmostPollInterval) { [weak self] in
            self?.waitUntilFrontmost(targetPID: targetPID, attempt: attempt + 1)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let keyCodeV: CGKeyCode = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func presentAccessibilityGuidance() {
        let alert = NSAlert()
        alert.messageText = "辅助功能未对本版本生效"
        alert.informativeText = """
        已将内容写入剪贴板，并已尝试自动粘贴。

        若系统设置里 HisCopy 已勾选，但本应用仍显示「未授权」，通常是 ad-hoc 签名更新后 TCC 仍绑定旧二进制：

        1. 打开「系统设置 → 隐私与安全性 → 辅助功能」
        2. 删除列表中所有 HisCopy 条目
        3. 点击「+」重新添加当前 HisCopy.app
        4. 完全退出并重新打开 HisCopy，再点「重新检查权限」

        授权前可回到原输入框手动 ⌘V。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
