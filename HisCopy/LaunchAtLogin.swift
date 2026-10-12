import AppKit
import ServiceManagement

/// Real 开机启动 via `SMAppService.mainApp` (macOS 13+). The toggle always
/// reflects the system's status, not a stored preference.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    private init() {
        refresh()
        // Stale pre-0.8.1 placeholder preference: no longer meaningful.
        UserDefaults.standard.removeObject(forKey: "launchAtLogin")
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = (enabled ? "无法开启开机启动：" : "无法关闭开机启动：") + error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
