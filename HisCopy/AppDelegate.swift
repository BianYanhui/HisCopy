import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var historyWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var hotKeyStatusMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    /// 打开面板前的前置应用，粘贴时再激活以便 ⌘V 命中正确目标。
    private var previousFrontmostApp: NSRunningApplication?
    /// Esc 关闭面板。
    private var escapeMonitor: Any?
    /// 点击面板外部关闭。
    private var clickOutsideMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observePauseState()
        observeHotKeyState()
        ClipboardMonitor.shared.start()

        let hotKeys = GlobalHotKeyManager.shared
        hotKeys.onHotKeyPressed = { [weak self] in
            self?.toggleHistoryPanel()
        }
        hotKeys.start()
        refreshHotKeyMenuPresentation()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillQuitForUpdate),
            name: .hisCopyWillQuitForUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideHistoryPanel),
            name: .hisCopyHideHistoryPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrepareForPaste(_:)),
            name: .hisCopyPrepareForPaste,
            object: nil
        )
        AppUpdater.shared.checkOnLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.stop()
        ClipboardMonitor.shared.stop()
        tearDownPanelDismissMonitors()
    }

    @objc private func handleWillQuitForUpdate() {
        GlobalHotKeyManager.shared.stop()
        ClipboardMonitor.shared.stop()
        tearDownPanelDismissMonitors()
        historyWindow?.orderOut(nil)
    }

    @objc private func handleHideHistoryPanel() {
        hideHistoryPanel()
    }

    @objc private func handlePrepareForPaste(_ notification: Notification) {
        let hide = (notification.userInfo?["hidePanel"] as? Bool) ?? true
        prepareForPasteToFrontmostApp(hidePanel: hide)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = statusImage(paused: ClipboardHistoryStore.shared.isPaused)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "HisCopy"
        }

        let menu = NSMenu()
        menu.autoenablesItems = true

        let historyItem = NSMenuItem(title: "显示/隐藏历史", action: #selector(toggleHistoryPanel), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        historyMenuItem = historyItem

        let hotKeyStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotKeyStatus.isEnabled = false
        menu.addItem(hotKeyStatus)
        hotKeyStatusMenuItem = hotKeyStatus

        let pauseItem = NSMenuItem(
            title: pauseTitle(paused: ClipboardHistoryStore.shared.isPaused),
            action: #selector(togglePauseCapture),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let autoUpdate = NSMenuItem(title: "自动检查更新", action: #selector(toggleAutoCheck), keyEquivalent: "")
        autoUpdate.target = self
        autoUpdate.state = AppUpdater.shared.autoCheckEnabled ? .on : .off
        menu.addItem(autoUpdate)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 HisCopy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func observePauseState() {
        ClipboardHistoryStore.shared.$isPaused
            .receive(on: RunLoop.main)
            .sink { [weak self] paused in
                self?.updatePauseUI(paused: paused)
            }
            .store(in: &cancellables)
    }

    private func observeHotKeyState() {
        let manager = GlobalHotKeyManager.shared
        manager.$shortcut
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshHotKeyMenuPresentation()
            }
            .store(in: &cancellables)
        manager.$registrationFailureMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshHotKeyMenuPresentation()
            }
            .store(in: &cancellables)
    }

    private func refreshHotKeyMenuPresentation() {
        let manager = GlobalHotKeyManager.shared
        let shortcut = manager.shortcut

        // 不把全局热键设为菜单 keyEquivalent：Carbon 已负责全局 shortcut。
        // 若菜单再挂同一组合，activate 后松手时 AppKit 可能再次触发 toggle 关掉面板。
        if let historyMenuItem {
            historyMenuItem.keyEquivalent = ""
            historyMenuItem.keyEquivalentModifierMask = []
        }

        if let hotKeyStatusMenuItem {
            if let failure = manager.registrationFailureMessage {
                hotKeyStatusMenuItem.title = "⚠️ \(failure)"
                hotKeyStatusMenuItem.isHidden = false
            } else {
                hotKeyStatusMenuItem.title = "全局快捷键：\(shortcut.displayString)"
                hotKeyStatusMenuItem.isHidden = false
            }
        }
    }

    private func updatePauseUI(paused: Bool) {
        pauseMenuItem?.title = pauseTitle(paused: paused)
        if let button = statusItem?.button {
            let image = statusImage(paused: paused)
            image?.isTemplate = true
            button.image = image
        }
    }

    private func pauseTitle(paused: Bool) -> String {
        paused ? "恢复捕获" : "暂停捕获"
    }

    private func statusImage(paused: Bool) -> NSImage? {
        let symbol = paused ? "pause.circle" : "doc.on.clipboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HisCopy")
        image?.isTemplate = true
        return image
    }

    @objc private func toggleHistoryPanel() {
        if let window = historyWindow, window.isVisible {
            hideHistoryPanel()
            return
        }
        showHistoryPanel()
    }

    private func hideHistoryPanel() {
        tearDownPanelDismissMonitors()
        historyWindow?.orderOut(nil)
        PanelPasteShortcutGate.shared.reset()
    }

    @objc private func showHistoryPanel() {
        if let window = historyWindow {
            presentHistoryWindow(window)
            return
        }

        let rootView = HistoryPanelView()
        let hosting = NSHostingController(rootView: rootView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "HisCopy"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 松手/短暂失活时不要自动消失；仅由热键再次按下、Esc、粘贴、点外部等关闭。
        window.hidesOnDeactivate = false
        window.contentViewController = hosting
        historyWindow = window
        presentHistoryWindow(window)
    }

    private func presentHistoryWindow(_ window: NSWindow) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = front
        }
        // 必须在成为 key window 之前上锁，避免呼出和弦落入面板 ⌘V / 回车。
        PanelPasteShortcutGate.shared.beginArmingAfterPanelOpen()
        // ⇧⌘V 呼出：始终居中于当前屏幕。
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installPanelDismissMonitors()
        // 每次打开（含 orderOut 后复用）通知面板：选中最新并滚到顶。
        NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
    }

    /// Esc 与点击外部关闭面板（再次 ⇧⌘V / 粘贴成功另有路径）。
    private func installPanelDismissMonitors() {
        tearDownPanelDismissMonitors()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // kVK_Escape = 53
            if event.keyCode == 53 {
                self.hideHistoryPanel()
                return nil
            }
            return event
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.historyWindow, window.isVisible else { return }
            let screenPoint = NSEvent.mouseLocation
            if !window.frame.contains(screenPoint) {
                // 状态栏按钮点击留给菜单，不在这里抢。
                if let button = self.statusItem?.button, let buttonWindow = button.window {
                    let buttonRect = button.convert(button.bounds, to: nil)
                    let buttonScreen = buttonWindow.convertToScreen(buttonRect)
                    if buttonScreen.contains(screenPoint) { return }
                }
                DispatchQueue.main.async {
                    self.hideHistoryPanel()
                }
            }
        }
    }

    private func tearDownPanelDismissMonitors() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    /// 供粘贴流程调用：收起面板，并把焦点交回先前前置应用。
    func prepareForPasteToFrontmostApp(hidePanel: Bool) {
        if hidePanel {
            self.hideHistoryPanel()
        }
        if let app = previousFrontmostApp, !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    @objc private func togglePauseCapture() {
        ClipboardHistoryStore.shared.togglePause()
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdatesFromMenu()
    }

    @objc private func toggleAutoCheck(_ sender: NSMenuItem) {
        AppUpdater.shared.autoCheckEnabled.toggle()
        sender.state = AppUpdater.shared.autoCheckEnabled ? .on : .off
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
