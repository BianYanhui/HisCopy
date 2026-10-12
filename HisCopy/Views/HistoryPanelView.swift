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
    @StateObject private var arrowKeyMonitor = PanelListArrowKeyMonitor()
    /// Debounce Carbon hotkey + local monitor both firing.
    @State private var lastPasteAt: Date?

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            insetDivider

            content

            insetDivider

            footerBar
        }
        .frame(minWidth: HisCopyStyle.panelMinWidth, minHeight: HisCopyStyle.panelMinHeight)
        .background { PanelChromeBackground() }
        .clipShape(RoundedRectangle(cornerRadius: HisCopyStyle.panelCornerRadius, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97, anchor: .center)
        .background(searchFocusShortcut)
        .onAppear {
            playAppearAnimation()
            selectNewest(clearSearch: false)
            // Do NOT focus search on open — arrows/numpad must navigate the list immediately.
            searchFocused = false
            arrowKeyMonitor.searchFocused = false
            arrowKeyMonitor.start()
        }
        .onDisappear {
            arrowKeyMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyHideHistoryPanel)) { _ in
            arrowKeyMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyHistoryPanelDidOpen)) { _ in
            playAppearAnimation()
            selectNewest(clearSearch: true)
            searchFocused = false
            arrowKeyMonitor.searchFocused = searchFocused
            arrowKeyMonitor.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyPanelEscapeRequested)) { _ in
            handleEscape()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyPanelMoveSelection)) { note in
            guard let delta = note.userInfo?["delta"] as? Int else { return }
            moveSelection(by: delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyPanelPastePlain)) { _ in
            guard pasteShortcutGate.isArmed else { return }
            pastePlainSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyPanelPasteFormatted)) { _ in
            guard pasteShortcutGate.isArmed else { return }
            pasteFormattedSelected()
        }
        .onExitCommand {
            handleEscape()
        }
        .onChange(of: searchFocused) { focused in
            arrowKeyMonitor.searchFocused = focused
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

    private var insetDivider: some View {
        Divider()
            .opacity(0.45)
            .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
    }

    /// Hidden ⌘F affordance to enter search mode without focusing the field on open.
    private var searchFocusShortcut: some View {
        Button("搜索") {
            searchFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handleEscape() {
        if searchFocused {
            searchFocused = false
            return
        }
        if !searchText.isEmpty {
            searchText = ""
            return
        }
        NotificationCenter.default.post(name: .hisCopyHideHistoryPanel, object: nil)
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

    /// Move list selection by delta (−1 up / +1 down). Used when search is unfocused.
    private func moveSelection(by delta: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let currentIndex: Int = {
            if let id = selection, let idx = items.firstIndex(where: { $0.id == id }) {
                return idx
            }
            // No selection: down → first, up → first (newest).
            return delta > 0 ? -1 : 0
        }()
        let newIndex = max(0, min(items.count - 1, currentIndex + delta))
        let newID = items[newIndex].id
        guard newID != selection else { return }
        withAnimation(HisCopyStyle.selection) {
            selection = newID
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
        guard acceptPasteTrigger() else { return }
        guard let item = selectedItem() else { return }
        pastePlain(item)
    }

    /// 回车：有格式原文 → 模拟粘贴 → 关闭面板。
    private func pasteFormattedSelected() {
        guard acceptPasteTrigger() else { return }
        guard let item = selectedItem() else { return }
        pasteFormatted(item)
    }

    private func acceptPasteTrigger() -> Bool {
        let now = Date()
        if let last = lastPasteAt, now.timeIntervalSince(last) < 0.35 {
            return false
        }
        lastPasteAt = now
        return true
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
            HStack(spacing: 8) {
                Text("历史")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)

                statusPill

                Spacer(minLength: 8)

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

                PanelIconButton(
                    systemName: "trash",
                    helpText: "清空全部历史（含收藏）",
                    disabled: store.items.isEmpty
                ) {
                    store.clearAll()
                    selection = nil
                }
                .accessibilityLabel("清空")
            }

            searchField
        }
        .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
        .padding(.top, HisCopyStyle.headerTopPadding)
        .padding(.bottom, HisCopyStyle.headerBottomPadding)
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(store.isPaused ? Color.secondary.opacity(0.55) : Color.accentColor)
                .frame(width: 5, height: 5)
            Text(store.isPaused ? "已暂停" : "捕获中")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(store.isPaused ? Color.secondary : Color.accentColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(store.isPaused
                      ? Color.primary.opacity(0.05)
                      : Color.accentColor.opacity(0.12))
        )
        .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(searchFocused ? Color.accentColor : Color.secondary)
            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
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
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: HisCopyStyle.searchFieldCorner, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HisCopyStyle.searchFieldCorner, style: .continuous)
                .strokeBorder(
                    searchFocused
                        ? Color.accentColor.opacity(0.50)
                        : Color.primary.opacity(0.08),
                    lineWidth: searchFocused ? 1 : 0.5
                )
        )
        .animation(HisCopyStyle.hover, value: searchFocused)
        .help("⌘F 聚焦搜索")
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            EmptyHistoryState(
                title: store.items.isEmpty ? "尚无历史" : "无匹配结果",
                subtitle: store.isPaused
                    ? "捕获已暂停"
                    : (store.items.isEmpty ? "复制内容后会出现在这里" : "试试其他关键词"),
                systemImage: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
            )
            .transition(
                .opacity.combined(with: .offset(y: -4))
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
                                top: 2,
                                leading: HisCopyStyle.rowHorizontalInset,
                                bottom: 2,
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
                                Button {
                                    store.toggleFavorite(id: item.id)
                                } label: {
                                    Label(
                                        item.isFavorite ? "取消收藏" : "收藏",
                                        systemImage: item.isFavorite ? "star.slash" : "star"
                                    )
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
                .opacity.combined(with: .offset(y: 3))
            )
        }
    }

    /// 底栏：左侧用量，右侧两枚动作按钮（键帽嵌在按钮内）。
    private var footerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.formattedUsageSummary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("收藏免于自动清理")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .help("收藏条目不计入自动清理；清空仍会删除全部。")
            .accessibilityLabel("历史 \(store.items.count) 条，约 \(ClipboardHistoryStore.formatByteCount(store.approximateTotalBytes))")

            Spacer(minLength: 8)

            Button {
                pastePlainSelected()
            } label: {
                HStack(spacing: 5) {
                    ShortcutKeyCap(label: "⌘V")
                    Text("纯文本")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection == nil)
            // ⌘V is handled by PanelPasteShortcutGate local monitor (nonactivating panel).
            .help("写入无格式纯文本并向前置应用发送 ⌘V，然后关闭面板")

            Button {
                pasteFormattedSelected()
            } label: {
                HStack(spacing: 5) {
                    ShortcutKeyCap(label: "↩")
                    Text("粘贴原文")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selection == nil)
            // Return is handled by PanelPasteShortcutGate local monitor (nonactivating panel).
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
                .scaleEffect(isSelected ? HisCopyStyle.selectionScale : 1)
                .animation(HisCopyStyle.selection, value: isSelected)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.textPreview)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected
                                      ? Color.accentColor.opacity(0.14)
                                      : Color.primary.opacity(0.06))
                        )

                    Text(HisCopyStyle.relativeTimeString(item.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.yellow.opacity(0.95))
                            .accessibilityHidden(true)
                    }
                }
            }

            favoriteButton
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
        .accessibilityLabel("\(item.kindLabel)，\(item.textPreview)\(item.isFavorite ? "，已收藏" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Trailing star: always reserves space; fades in on hover/selection; solid when favorited.
    private var favoriteButton: some View {
        Button {
            withAnimation(HisCopyStyle.selection) {
                store.toggleFavorite(id: item.id)
            }
        } label: {
            Image(systemName: item.isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                .opacity(item.isFavorite || isHovered || isSelected ? 1 : 0)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(item.isFavorite
                              ? Color.yellow.opacity(0.14)
                              : (isHovered || isSelected ? Color.primary.opacity(0.05) : Color.clear))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(item.isFavorite ? "取消收藏" : "收藏（免于按容量/时间自动清理）")
        .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if item.kind == .image, let name = item.imageFileName,
           let image = store.loadImage(named: name) {
            ThumbnailImage(image: image, isSelected: isSelected)
        } else {
            SymbolWell(systemName: item.symbolName, isSelected: isSelected)
        }
    }
}


/// Local key monitor so ↑/↓ (and numpad 8/2) move selection without clicking the list.
/// Borderless `NSPanel` + unfocused search leaves no List first-responder; this fills the gap.
@MainActor
private final class PanelListArrowKeyMonitor: ObservableObject {
    var searchFocused = false
    private var monitor: Any?

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard !self.searchFocused else { return event }

            // Panel may be key without HisCopy being the active app (.nonactivatingPanel).
            guard let key = NSApp.keyWindow,
                  key.isVisible,
                  key.title == "HisCopy" else {
                return event
            }

            // Let real text editing keep arrow keys (e.g. if focus leaked to a field).
            if let fr = key.firstResponder {
                if fr is NSTextView || fr is NSTextField {
                    return event
                }
            }

            // Ignore when Command/Option/Control held; allow bare arrows (and fn/numpad bits).
            let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard chord.isEmpty else { return event }

            let delta: Int
            switch event.keyCode {
            case 125: delta = 1   // ↓
            case 126: delta = -1  // ↑
            case 84:  delta = 1   // keypad 2
            case 91:  delta = -1  // keypad 8
            default:
                return event
            }
            NotificationCenter.default.post(
                name: .hisCopyPanelMoveSelection,
                object: nil,
                userInfo: ["delta": delta]
            )
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

#Preview {
    HistoryPanelView()
}
