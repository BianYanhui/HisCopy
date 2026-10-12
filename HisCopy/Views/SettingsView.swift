import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject private var pasteController = PasteController.shared

    /// Always in-range for the current unit — Stepper crashes if value ∉ `in:`.
    private var retentionAgeRange: ClosedRange<Int> {
        store.retentionAgeUnit.minValue...store.retentionAgeUnit.maxValue
    }

    private var retentionAgeValueBinding: Binding<Int> {
        Binding(
            get: {
                let range = retentionAgeRange
                return min(max(store.retentionAgeValue, range.lowerBound), range.upperBound)
            },
            set: { store.retentionAgeValue = $0 }
        )
    }

    private var retentionAgeUnitBinding: Binding<RetentionAgeUnit> {
        Binding(
            get: { store.retentionAgeUnit },
            set: { store.setRetentionAgeUnit($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("暂停捕获", isOn: $store.isPaused)

                LabeledContent("当前用量") {
                    Text(store.formattedUsageSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker("存储上限", selection: $store.maxStorageMB) {
                    ForEach(ClipboardHistoryStore.storageMBPresets, id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("保留时长")
                    HStack(spacing: 12) {
                        Picker("单位", selection: retentionAgeUnitBinding) {
                            ForEach(RetentionAgeUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 200)

                        Stepper(value: retentionAgeValueBinding, in: retentionAgeRange) {
                            Text("\(retentionAgeValueBinding.wrappedValue) \(store.retentionAgeUnit.label)")
                                .monospacedDigit()
                                .frame(minWidth: 72, alignment: .leading)
                        }
                    }
                }

                Button("清空历史", role: .destructive) {
                    store.clearAll()
                }
                .disabled(store.items.isEmpty)
            } header: {
                Text("剪贴板")
            } footer: {
                Text("超出存储上限或保留时长时，自动丢弃最旧的非收藏条目。收藏条目不会被自动清理；「清空历史」仍会删除全部（含收藏）。面板中：⌘V 粘贴纯文本并关闭；回车粘贴原文并关闭；⌘F 搜索。")
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
        .frame(width: 520, height: 620)
        .onAppear {
            // Normalize before first paint so Stepper `in:` always contains value.
            store.setRetentionAgeUnit(store.retentionAgeUnit)
            pasteController.refreshAccessibilityStatus()
        }
    }
}

#Preview {
    SettingsView()
}
