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
            button.image = statusImage(paused: ClipboardHistoryStore.shared.isPaused)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

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

        menu.addItem(NSMenuItem.separator())

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

        menu.addItem(NSMenuItem.separator())

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
            button.image = statusImage(paused: paused)
            button.image?.isTemplate = true
        }
    }

    private func pauseTitle(paused: Bool) -> String {
        paused ? "恢复捕获" : "暂停捕获"
    }

    private func statusImage(paused: Bool) -> NSImage? {
        let symbol = paused ? "pause.circle" : "doc.on.clipboard"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "HisCopy")
    }

    @objc private func showHistoryPanel() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HistoryPanelView()
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HisCopy 历史"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
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
