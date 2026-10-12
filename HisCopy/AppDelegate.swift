import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var historyWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var hotKeyStatusMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    /// 打开面板前的前置应用，粘贴时再激活以便 ⌘V 命中正确目标。
    private var previousFrontmostApp: NSRunningApplication?

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
    }

    @objc private func handleWillQuitForUpdate() {
        GlobalHotKeyManager.shared.stop()
        ClipboardMonitor.shared.stop()
        historyWindow?.orderOut(nil)
    }

    @objc private func handleHideHistoryPanel() {
        historyWindow?.orderOut(nil)
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
            button.toolTip = "HisCopy — 左键打开历史，右键打开菜单"
            button.target = self
            button.action = #selector(statusItemButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        // 不永久挂 menu：左键走 action 呼出面板，右键/Option+点击再弹出菜单。
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemButtonClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggleHistoryPanel()
            return
        }
        let isRight = event.type == .rightMouseUp
        let isOption = event.modifierFlags.contains(.option)
        if isRight || isOption {
            popUpStatusMenu()
        } else {
            toggleHistoryPanel()
        }
    }

    private func popUpStatusMenu() {
        guard let menu = statusMenu, let button = statusItem?.button else { return }
        // 直接在按钮下方弹出，不永久挂 item.menu，这样左键仍走 action。
        let point = NSPoint(x: 0, y: button.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: button)
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

        if let historyMenuItem {
            let equiv = shortcut.menuKeyEquivalent
            if manager.registrationFailureMessage == nil, !equiv.isEmpty {
                historyMenuItem.keyEquivalent = equiv
                historyMenuItem.keyEquivalentModifierMask = shortcut.cocoaModifierFlags
            } else {
                historyMenuItem.keyEquivalent = ""
                historyMenuItem.keyEquivalentModifierMask = []
            }
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
            window.orderOut(nil)
            return
        }
        showHistoryPanel()
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
        window.contentViewController = hosting
        historyWindow = window
        presentHistoryWindow(window)
    }

    private func presentHistoryWindow(_ window: NSWindow) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = front
        }
        positionHistoryWindowNearStatusItem(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 供粘贴流程调用：可选收起面板，并尝试把焦点交回先前前置应用。
    func prepareForPasteToFrontmostApp(hidePanel: Bool) {
        if hidePanel {
            historyWindow?.orderOut(nil)
        }
        if let app = previousFrontmostApp, !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// 尽量把面板锚定在菜单栏图标下方；无法取得图标位置时回退到居中。
    private func positionHistoryWindowNearStatusItem(_ window: NSWindow) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else {
            if !window.isVisible {
                window.center()
            }
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        var frame = window.frame
        let gap: CGFloat = 6
        frame.origin.x = buttonScreenRect.midX - frame.width / 2
        frame.origin.y = buttonScreenRect.minY - frame.height - gap

        // 约束在可见屏幕内。
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - frame.width - 8
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX + 8
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY + 8
            }
        }
        window.setFrame(frame, display: true)
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
