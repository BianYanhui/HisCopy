import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject private var pasteController = PasteController.shared
    @ObservedObject private var presentation = PanelPresentation.shared

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
                        .font(.callout)
                }

                Picker("存储上限", selection: $store.maxStorageMB) {
                    ForEach(ClipboardHistoryStore.storageMBPresets, id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("保留时长")
                        .font(.body)
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
                Label("剪贴板", systemImage: "doc.on.clipboard")
            } footer: {
                Text("超出存储上限或保留时长时，自动丢弃最旧的非收藏条目。收藏条目不会被自动清理；「清空历史」仍会删除全部（含收藏）。面板中：⌘V 粘贴纯文本并关闭；回车粘贴原文并关闭；⌘F 搜索。")
            }

            Section {
                LabeledContent("辅助功能") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(pasteController.isAccessibilityTrusted ? Color.green.opacity(0.85) : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(pasteController.isAccessibilityTrusted ? "已授权（本进程）" : "未授权（本进程）")
                            .foregroundStyle(pasteController.isAccessibilityTrusted ? Color.secondary : Color.orange)
                    }
                }
                if let hint = pasteController.trustHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("打开「隐私与安全性 → 辅助功能」…") {
                    pasteController.openAccessibilitySettings()
                }
                Button("重新检查权限") {
                    _ = pasteController.refreshAccessibilityStatus(prompt: false)
                }
                Button("请求系统授权对话框…") {
                    _ = pasteController.refreshAccessibilityStatus(prompt: true)
                }
            } header: {
                Label("粘贴", systemImage: "doc.on.clipboard.fill")
            } footer: {
                Text("一键粘贴用 Accessibility / CGEvent 模拟 ⌘V。状态针对「当前正在运行的这份」HisCopy：ad-hoc 更新后系统列表里勾选的可能是旧二进制，会出现「设置里已开、这里仍显示未授权」。请删除列表中所有 HisCopy 后重新添加当前 .app，并重启应用。粘贴时仍会尝试发送 ⌘V，不因该指示灯而放弃。")
            }

            Section {
                Picker("面板位置", selection: $presentation.dockingEnabled) {
                    Text("不吸附").tag(false)
                    Text("吸附").tag(true)
                }
                .pickerStyle(.segmented)

                if presentation.dockingEnabled {
                    Picker("吸附边缘", selection: $presentation.dockEdge) {
                        ForEach(PanelEdge.selectable) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Picker("外观", selection: $presentation.appearance) {
                    ForEach(PanelAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("面板", systemImage: "sidebar.right")
            } footer: {
                Text(presentation.dockingEnabled
                     ? "吸附：面板收起为屏幕边缘的一条细条，鼠标移到细条处即滑出，移开自动收回（点过面板后保持展开，Esc / 点外部 / 粘贴后收回）。⇧⌘V 从边缘弹出。拖动标题「历史」可沿边缘移动或拖到另一侧 / 顶部 / 另一块屏幕，位置自动记住。"
                     : "不吸附：⇧⌘V 在屏幕正中呼出面板（与以往一致）。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("呼出/隐藏历史")
                        .font(.body)
                    HotKeyRecorderView()
                }
            } header: {
                Label("全局快捷键", systemImage: "keyboard")
            } footer: {
                Text("默认 ⇧⌘V（Shift+Command+V）：不吸附时面板显示在屏幕正中，吸附时从边缘弹出。使用系统 Carbon RegisterEventHotKey，改后立即生效。仅打开面板通常无需辅助功能权限；模拟 ⌘V 粘贴才需要。菜单栏图标使用常规菜单。")
            }

            Section {
                Toggle("开机时启动 HisCopy", isOn: $launchAtLogin)
            } header: {
                Label("通用", systemImage: "gearshape")
            } footer: {
                Text("开机自启尚未接入系统服务，开关仅作偏好占位。")
            }

            Section {
                Toggle("自动检查更新", isOn: $updater.autoCheckEnabled)
                LabeledContent("当前版本") {
                    Text("\(AppUpdater.currentVersion())（\(AppUpdater.currentBuild())）")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .font(.callout)
                }
                Button("检查更新…") {
                    updater.checkForUpdatesFromMenu()
                }
                .disabled(updater.isBusy)
            } header: {
                Label("更新", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("从 GitHub Releases 检查并下载 HisCopy.zip。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 660)
        .onAppear {
            // Normalize before first paint so Stepper `in:` always contains value.
            store.setRetentionAgeUnit(store.retentionAgeUnit)
            _ = pasteController.refreshAccessibilityStatus(prompt: false)
        }
    }
}

#Preview {
    SettingsView()
}
