import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        Form {
            Section("剪贴板") {
                Toggle("暂停捕获", isOn: $store.isPaused)
                LabeledContent("历史条数", value: "\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                Button("清空历史", role: .destructive) {
                    store.clearAll()
                }
                .disabled(store.items.isEmpty)
            }

            Section("通用") {
                // 占位：暂不真正注册 SMAppService
                Toggle("开机时启动 HisCopy", isOn: $launchAtLogin)
            }

            Section("更新") {
                Toggle("自动检查更新", isOn: $updater.autoCheckEnabled)
                HStack {
                    Text("当前版本 \(AppUpdater.currentVersion())（\(AppUpdater.currentBuild())）")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("检查更新…") { updater.checkForUpdatesFromMenu() }
                        .disabled(updater.isBusy)
                }
            }

            Section("关于") {
                Text("选中历史条目会复制回系统剪贴板；本版本不模拟按键粘贴（无需辅助功能权限）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .padding()
    }
}

#Preview {
    SettingsView()
}
