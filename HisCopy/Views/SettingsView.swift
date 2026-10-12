import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject private var pasteController = PasteController.shared

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
                Text("在历史面板中：⌘V 粘贴无格式纯文本并关闭；回车粘贴有格式原文并关闭。")
            }

            Section {
                LabeledContent("辅助功能") {
                    Text(pasteController.isAccessibilityTrusted ? "已授权" : "未授权")
                        .foregroundStyle(pasteController.isAccessibilityTrusted ? Color.secondary : Color.orange)
                }
                Button("打开「隐私与安全性 → 辅助功能」…") {
                    pasteController.openAccessibilitySettings()
                }
                Button("重新检查权限") {
                    pasteController.refreshAccessibilityStatus()
                }
            } header: {
                Text("粘贴")
            } footer: {
                Text("一键粘贴使用 Accessibility / CGEvent 模拟 ⌘V。未授权时仅写入剪贴板，并提示前往系统设置授权。可在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 HisCopy。")
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
                Text("默认 ⇧⌘V（Shift+Command+V），面板显示在屏幕正中。使用系统 Carbon RegisterEventHotKey，改后立即生效。仅打开面板通常无需辅助功能权限；模拟 ⌘V 粘贴才需要。菜单栏图标使用常规菜单。")
            }

            Section {
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
        .frame(width: 500, height: 540)
        .onAppear {
            pasteController.refreshAccessibilityStatus()
        }
    }
}

#Preview {
    SettingsView()
}
