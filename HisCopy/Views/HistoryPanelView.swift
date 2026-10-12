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

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbarStrip

                Divider()
                    .opacity(0.45)
                    .padding(.horizontal, 8)

                content

                Divider()
                    .opacity(0.45)
                    .padding(.horizontal, 8)

                footerBar
            }
            .navigationTitle("历史")
            .navigationSubtitle(store.isPaused ? "已暂停" : "捕获中")
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索历史")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        store.clearAll()
                        selection = nil
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(store.items.isEmpty)
                    .help("清空全部历史")
                }
            }
        }
        .frame(minWidth: HisCopyStyle.panelMinWidth, minHeight: HisCopyStyle.panelMinHeight)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // 极轻内侧描边，提升浅色桌面上的面板轮廓可读性（Pulse PanelLight 思路）。
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .center)
        .onAppear {
            playAppearAnimation()
            selectNewest(clearSearch: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyHistoryPanelDidOpen)) { _ in
            playAppearAnimation()
            selectNewest(clearSearch: true)
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

    private var toolbarStrip: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { !store.isPaused },
                set: { store.isPaused = !$0 }
            )) {
                Label(
                    store.isPaused ? "已暂停" : "捕获中",
                    systemImage: store.isPaused ? "pause.circle" : "record.circle"
                )
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(store.isPaused ? .secondary : .primary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(store.isPaused ? "恢复剪贴板捕获" : "暂停剪贴板捕获")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
        .padding(.vertical, HisCopyStyle.stripVerticalPadding)
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

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text("\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                ShortcutKeyCap(label: "⌘V")
                Text("纯文本")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                ShortcutKeyCap(label: "↩")
                Text("有格式")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("⌘V 粘贴纯文本，回车粘贴有格式")

            Button {
                pastePlainSelected()
            } label: {
                Label("纯文本", systemImage: "doc.plaintext")
            }
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
                Label("粘贴原文", systemImage: "doc.richtext")
            }
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
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.quaternary.opacity(0.7))
                        )

                    Text(HisCopyStyle.relativeTimeString(item.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
