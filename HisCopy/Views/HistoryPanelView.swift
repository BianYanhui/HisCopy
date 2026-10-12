import SwiftUI
import AppKit

struct HistoryPanelView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject private var pasteShortcutGate = PanelPasteShortcutGate.shared
    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var appeared = false
    /// 递增以请求 List 滚到当前 selection（打开面板 / 清空搜索）。
    @State private var scrollNonce = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 10)

            content

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 10)

            footerBar
        }
        .frame(minWidth: HisCopyStyle.panelMinWidth, minHeight: HisCopyStyle.panelMinHeight)
        .background { PanelChromeBackground() }
        .clipShape(RoundedRectangle(cornerRadius: HisCopyStyle.panelCornerRadius, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .center)
        .onAppear {
            playAppearAnimation()
            selectNewest(clearSearch: false)
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyHistoryPanelDidOpen)) { _ in
            playAppearAnimation()
            selectNewest(clearSearch: true)
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                selectNewest(clearSearch: false)
            } else if selection == nil || !filtered.contains(where: { $0.id == selection }) {
                selection = filtered.first?.id
                scrollNonce += 1
            }
        }
    }

    private func playAppearAnimation() {
        appeared = false
        withAnimation(HisCopyStyle.panelAppear) {
            appeared = true
        }
    }

    /// 选中列表第一条（最新）并请求滚到顶部。
    private func selectNewest(clearSearch: Bool) {
        if clearSearch {
            searchText = ""
        }
        let items = store.filtered(search: clearSearch ? "" : searchText)
        withAnimation(HisCopyStyle.selection) {
            selection = items.first?.id
        }
        scrollNonce += 1
    }

    private func scrollSelectionToTop(using proxy: ScrollViewProxy) {
        guard let id = selection ?? filtered.first?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// ⌘V：无格式纯文本 → 模拟粘贴 → 关闭面板。
    /// 快捷键路径受 `PanelPasteShortcutGate` 保护；鼠标点击按钮始终可用。
    private func pastePlainSelected() {
        guard let item = selectedItem() else { return }
        pastePlain(item)
    }

    /// 回车：有格式原文 → 模拟粘贴 → 关闭面板。
    private func pasteFormattedSelected() {
        guard let item = selectedItem() else { return }
        pasteFormatted(item)
    }

    private func pastePlain(_ item: ClipboardItem) {
        store.copyPlainTextToPasteboard(item)
        PasteController.shared.pasteToFrontmostAppAndClose()
    }

    private func pasteFormatted(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        PasteController.shared.pasteToFrontmostAppAndClose()
    }

    private func selectedItem() -> ClipboardItem? {
        guard let id = selection else { return nil }
        return filtered.first(where: { $0.id == id })
            ?? store.items.first(where: { $0.id == id })
    }

    // MARK: - Header (custom — no NavigationStack / titlebar chrome)

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("历史")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(store.isPaused ? "已暂停" : "捕获中")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(store.isPaused ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(store.isPaused
                                  ? Color.primary.opacity(0.06)
                                  : Color.accentColor.opacity(0.14))
                    )

                Spacer(minLength: 0)

                Toggle(isOn: Binding(
                    get: { !store.isPaused },
                    set: { store.isPaused = !$0 }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(store.isPaused ? "恢复剪贴板捕获" : "暂停剪贴板捕获")
                .accessibilityLabel(store.isPaused ? "已暂停捕获" : "捕获中")

                Button {
                    store.clearAll()
                    selection = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(store.items.isEmpty)
                .help("清空全部历史")
                .accessibilityLabel("清空")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索历史", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            EmptyHistoryState(
                title: store.items.isEmpty ? "尚无历史" : "无匹配结果",
                subtitle: store.isPaused ? "捕获已暂停" : (store.items.isEmpty ? "复制内容后会出现在这里" : nil),
                systemImage: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
            )
            .transition(
                .opacity.combined(with: .offset(y: -6))
            )
        } else {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        HistoryRow(item: item, isSelected: selection == item.id)
                            .tag(item.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(
                                top: 3,
                                leading: HisCopyStyle.rowHorizontalInset,
                                bottom: 3,
                                trailing: HisCopyStyle.rowHorizontalInset
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button {
                                    pastePlain(item)
                                } label: {
                                    Label("粘贴纯文本（⌘V）", systemImage: "doc.plaintext")
                                }
                                Button {
                                    pasteFormatted(item)
                                } label: {
                                    Label("粘贴原文（↩）", systemImage: "doc.richtext")
                                }
                                Button {
                                    store.copyToPasteboard(item)
                                } label: {
                                    Label("仅复制到剪贴板", systemImage: "doc.on.doc")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    store.remove(id: item.id)
                                    if selection == item.id { selection = nil }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.remove(id: filtered[index].id)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(HisCopyStyle.selection, value: selection)
                .onAppear {
                    scrollSelectionToTop(using: proxy)
                }
                .onChange(of: scrollNonce) { _ in
                    scrollSelectionToTop(using: proxy)
                }
            }
            .transition(
                .opacity.combined(with: .offset(y: 4))
            )
        }
    }

    /// 底栏：左侧计数，右侧两枚动作按钮（键帽嵌在按钮内，去掉重复提示簇）。
    private var footerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("历史 \(store.items.count) 条，上限 \(ClipboardHistoryStore.maxItems)")

            Spacer(minLength: 8)

            Button {
                pastePlainSelected()
            } label: {
                HStack(spacing: 5) {
                    ShortcutKeyCap(label: "⌘V")
                    Text("纯文本")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection == nil)
            .modifier(PanelPasteKeyboardShortcut(
                isArmed: pasteShortcutGate.isArmed,
                key: "v",
                modifiers: .command
            ))
            .help("写入无格式纯文本并向前置应用发送 ⌘V，然后关闭面板")

            Button {
                pasteFormattedSelected()
            } label: {
                HStack(spacing: 5) {
                    ShortcutKeyCap(label: "↩")
                    Text("粘贴原文")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selection == nil)
            .modifier(PanelPasteDefaultActionShortcut(isArmed: pasteShortcutGate.isArmed))
            .help("按原样写入剪贴板并向前置应用发送 ⌘V，然后关闭面板")
        }
        .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
        .padding(.vertical, HisCopyStyle.footerVerticalPadding)
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    var isSelected: Bool = false
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: HisCopyStyle.contentSpacing) {
            leadingVisual
                .scaleEffect(isSelected ? 1.04 : 1)
                .animation(HisCopyStyle.selection, value: isSelected)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.textPreview)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )

                    Text(HisCopyStyle.relativeTimeString(item.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, HisCopyStyle.rowVerticalPadding)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HistoryRowHighlight(isSelected: isSelected, isHovered: isHovered && !isSelected)
        }
        .onHover { hovering in
            withAnimation(HisCopyStyle.hover) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kindLabel)，\(item.textPreview)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if item.kind == .image, let name = item.imageFileName,
           let image = store.loadImage(named: name) {
            ThumbnailImage(image: image)
        } else {
            SymbolWell(systemName: item.symbolName)
        }
    }
}

/// 仅在闸门解锁后挂载面板内粘贴快捷键，避免与全局呼出热键抢事件。
private struct PanelPasteKeyboardShortcut: ViewModifier {
    let isArmed: Bool
    let key: KeyEquivalent
    let modifiers: EventModifiers

    @ViewBuilder
    func body(content: Content) -> some View {
        if isArmed {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

private struct PanelPasteDefaultActionShortcut: ViewModifier {
    let isArmed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isArmed {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

#Preview {
    HistoryPanelView()
}
