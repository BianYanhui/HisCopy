import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var historyWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observePauseState()
        ClipboardMonitor.shared.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillQuitForUpdate),
            name: .hisCopyWillQuitForUpdate,
            object: nil
        )
        AppUpdater.shared.checkOnLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardMonitor.shared.stop()
    }

    @objc private func handleWillQuitForUpdate() {
        ClipboardMonitor.shared.stop()
        historyWindow?.orderOut(nil)
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

        let historyItem = NSMenuItem(title: "显示历史", action: #selector(showHistoryPanel), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

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
        window.contentViewController = hosting
        historyWindow = window
        presentHistoryWindow(window)
    }

    private func presentHistoryWindow(_ window: NSWindow) {
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
