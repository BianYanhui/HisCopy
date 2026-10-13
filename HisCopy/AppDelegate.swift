import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var historyWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var hotKeyStatusMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    /// Esc 关闭面板。
    private var escapeMonitor: Any?
    /// 点击面板外部关闭。
    private var clickOutsideMonitor: Any?
    /// Dedicated settings window (accessory apps: Settings scene alone is unreliable).
    private var settingsWindow: NSWindow?

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
        // Reliable ⇧⌘V needs Accessibility (CGEvent tap). Prompt once if missing.
        if !PasteController.shared.isAccessibilityTrusted {
            GlobalHotKeyManager.shared.refreshAccessibilityDependentPaths(prompt: true)
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyPanelPresentation),
            name: .hisCopyPanelPresentationChanged,
            object: nil
        )
        let dock = DockedPanelController.shared
        dock.installDismissMonitors = { [weak self] in self?.installPanelDismissMonitors() }
        dock.tearDownDismissMonitors = { [weak self] in self?.tearDownPanelDismissMonitors() }
        applyPanelPresentation()
        AppUpdater.shared.checkOnLaunchIfNeeded()
    }

    private var isDocking: Bool { PanelPresentation.shared.dockingEnabled }

    /// 吸附 / 不吸附 switched, or the dock edge changed in Settings.
    @objc private func applyPanelPresentation() {
        let dock = DockedPanelController.shared
        if isDocking {
            if let window = historyWindow, window.isVisible {
                tearDownPanelDismissMonitors()
                window.orderOut(nil)
                PanelPasteShortcutGate.shared.reset()
            }
            if dock.isInstalled {
                dock.reloadPlacement()
            } else {
                dock.install()
            }
        } else if dock.isInstalled {
            dock.uninstall()
        }
    }

    /// The window click-outside dismissal is measured against.
    private var activePanelWindow: NSWindow? {
        isDocking ? DockedPanelController.shared.window : historyWindow
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
        DockedPanelController.shared.uninstall()
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
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            button.toolTip = "HisCopy \(ver) (\(build))"
        }

        let menu = NSMenu()
        menu.autoenablesItems = true

        let historyItem = NSMenuItem(title: "显示/隐藏历史", action: #selector(toggleHistoryPanel), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        historyMenuItem = historyItem

        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let versionItem = NSMenuItem(title: "HisCopy \(ver) (\(build))", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

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
        manager.$eventTapActive
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshHotKeyMenuPresentation()
            }
            .store(in: &cancellables)
        PasteController.shared.$isAccessibilityTrusted
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
            } else if !PasteController.shared.isAccessibilityTrusted || !manager.eventTapActive {
                hotKeyStatusMenuItem.title = "⚠️ 全局快捷键需辅助功能（\(shortcut.displayString)）"
            } else {
                hotKeyStatusMenuItem.title = "全局快捷键：\(shortcut.displayString)"
            }
            hotKeyStatusMenuItem.isHidden = false
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
        if isDocking {
            DockedPanelController.shared.toggleFromHotKey()
            return
        }
        let visible = historyWindow?.isVisible == true
        HotKeyTrace.line("undocked toggle visible=\(visible)")
        if visible {
            hideHistoryPanel()
            return
        }
        showHistoryPanel()
    }

    private func hideHistoryPanel(animated: Bool = true) {
        if isDocking {
            DockedPanelController.shared.retract()
            return
        }
        tearDownPanelDismissMonitors()
        guard let window = historyWindow else {
            PanelPasteShortcutGate.shared.reset()
            return
        }
        let finish: () -> Void = {
            window.orderOut(nil)
            window.alphaValue = 1
            PanelPasteShortcutGate.shared.reset()
        }
        // 粘贴路径必须立刻收起，避免焦点交还竞态；Esc/热键/点外部可短 fade。
        guard animated, window.isVisible else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            finish()
        })
    }

    @objc private func showHistoryPanel() {
        if let window = historyWindow {
            // Recreate if this process still holds a pre-0.7.2 activating panel.
            if !window.styleMask.contains(.nonactivatingPanel) {
                window.orderOut(nil)
                historyWindow = nil
            } else {
                presentHistoryWindow(window)
                return
            }
        }

        let hosting = NSHostingController(rootView: CenteredPanelRoot())

        // Borderless + nonactivating: panel can be key for search/shortcuts without
        // activating HisCopy, so the destination dialog keeps focus (Spotlight-like).
        let window = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "HisCopy"
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Show above modal dialogs / sheets of other apps.
        window.worksWhenModal = true
        // 松手/短暂失活时不要自动消失；仅由热键再次按下、Esc、粘贴、点外部等关闭。
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.contentViewController = hosting
        historyWindow = window
        presentHistoryWindow(window)
    }

    private func presentHistoryWindow(_ window: NSWindow) {
        // Ensure style even if an older window instance was created before v0.7.2.
        if let panel = window as? NSPanel {
            panel.styleMask.insert(.nonactivatingPanel)
            panel.worksWhenModal = true
            panel.becomesKeyOnlyIfNeeded = true
        }

        // Capture destination while it is still frontmost (we must NOT NSApp.activate).
        PasteFocusCoordinator.shared.captureFromFrontmostApplication()
        // Lock paste until open chord releases; monitor stays for ⌘V / Return.
        PanelPasteShortcutGate.shared.beginArmingAfterPanelOpen()

        window.alphaValue = 1
        window.center()
        // v0.8.6: never makeKeyAndOrderFront — kills Carbon Pressed (see hotkey.log).
        // orderFrontRegardless only (Pulse). Click the panel to focus search.
        window.orderFrontRegardless()
        // Do NOT call NSApp.activate / makeKeyAndOrderFront.
        installPanelDismissMonitors()
        NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
        HotKeyTrace.line("undocked present (no makeKey)")
    }

    /// Esc 与点击外部关闭面板（再次 ⇧⌘V / 粘贴成功另有路径）。
    private func installPanelDismissMonitors() {
        tearDownPanelDismissMonitors()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // kVK_Escape = 53 — let the panel dismiss search first, then close.
            if event.keyCode == 53 {
                NotificationCenter.default.post(name: .hisCopyPanelEscapeRequested, object: nil)
                return nil
            }
            return event
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.activePanelWindow, window.isVisible else { return }
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

    /// Hide panel for paste. With nonactivating panel, destination usually still
    /// frontmost; only restore if we somehow became active.
    func prepareForPasteToFrontmostApp(hidePanel: Bool) {
        if hidePanel, isDocking {
            DockedPanelController.shared.retractForPaste()
        } else if hidePanel {
            self.hideHistoryPanel(animated: false)
        }
        _ = PasteFocusCoordinator.shared.restoreDestinationAppIfNeeded()
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
        // Menu-bar (.accessory) apps: SwiftUI Settings scene + showSettingsWindow:
        // often fails to key after Form crashes or on first paint. Host SettingsView
        // in our own titled window so 设置… always works.
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "HisCopy 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}


