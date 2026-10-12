import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("暂停捕获", isOn: $store.isPaused)
                LabeledContent("历史条数") {
                    Text("\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("清空历史", role: .destructive) {
                    store.clearAll()
                }
                .disabled(store.items.isEmpty)
            } header: {
                Text("剪贴板")
            } footer: {
                Text("选中历史条目会复制回系统剪贴板；本版本不模拟按键粘贴（无需辅助功能权限）。")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("呼出/隐藏历史")
                        .font(.body)
                    HotKeyRecorderView()
                }
            } header: {
                Text("全局快捷键")
            } footer: {
                Text("默认 ⇧⌘V（Shift+Command+V）。使用系统 Carbon RegisterEventHotKey，改后立即生效并写入偏好设置。仅打开面板，通常无需辅助功能（Accessibility）权限；模拟 ⌘V 粘贴才需要，本应用不模拟粘贴。")
            }

            Section {
                // 占位：暂不真正注册 SMAppService
                Toggle("开机时启动 HisCopy", isOn: $launchAtLogin)
            } header: {
                Text("通用")
            } footer: {
                Text("开机自启尚未接入系统服务，开关仅作偏好占位。")
            }

            Section {
                Toggle("自动检查更新", isOn: $updater.autoCheckEnabled)
                LabeledContent("当前版本") {
                    Text("\(AppUpdater.currentVersion())（\(AppUpdater.currentBuild())）")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("检查更新…") {
                    updater.checkForUpdatesFromMenu()
                }
                .disabled(updater.isBusy)
            } header: {
                Text("更新")
            } footer: {
                Text("从 GitHub Releases 检查并下载 HisCopy.zip。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
    }
}

#Preview {
    SettingsView()
}
