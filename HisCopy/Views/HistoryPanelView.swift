import SwiftUI
import AppKit

// Restyled in v0.8.0 with Pulse's panel language (see Styles.swift and
// THIRD_PARTY_NOTICES.md); layout and behaviour are HisCopy's own.
struct HistoryPanelView: View {
    /// Docked (吸附) panels get their surface from the berth and a drag handle.
    let docked: Bool

    init(docked: Bool = false) {
        self.docked = docked
    }
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
    /// Preview of the selected row (v0.8.1); toggled from the header.
    @AppStorage("panel.preview.enabled") private var showsPreview = true

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            insetDivider

            content

            if showsPreview, !filtered.isEmpty, let item = selectedItem() {
                insetDivider
                SelectionPreview(item: item)
                    .frame(height: HisCopyStyle.previewHeight)
                    .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
                    .padding(.vertical, 10)
                    .transition(.opacity)
            }

            insetDivider

            footerBar
        }
        .frame(
            minWidth: docked ? nil : HisCopyStyle.panelMinWidth,
            minHeight: docked ? nil : HisCopyStyle.panelMinHeight
        )
        // Centered: Pulse-spring appear. Docked: the berth spring does the motion.
        .opacity(docked || appeared ? 1 : 0)
        .scaleEffect(docked || appeared ? 1 : 0.97, anchor: .center)
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
        .onReceive(NotificationCenter.default.publisher(for: .hisCopyPanelQuickPick)) { note in
            guard pasteShortcutGate.isArmed, let index = note.userInfo?["index"] as? Int else { return }
            quickPick(index)
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

    /// Pulse separates with a hairline of the track colour, not a system Divider.
    private var insetDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
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

    /// 1–9: paste the Nth visible row as-is (same as selecting it and pressing ↩).
    private func quickPick(_ index: Int) {
        let items = filtered
        guard index >= 0, index < items.count else { return }
        guard acceptPasteTrigger() else { return }
        selection = items[index].id
        pasteFormatted(items[index])
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
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("历史")
                    .font(HisCopyStyle.font(HisCopyStyle.titleFontSize, .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    // Grab here to move the panel (along / between screen edges when docked).
                    .background(DockDragHandle(docked: docked))
                    .help(docked ? "拖动以沿屏幕边缘移动或换边" : "拖动以移动面板")

                statusPill

                Spacer(minLength: 8)

                Toggle(isOn: Binding(
                    get: { !store.isPaused },
                    set: { store.isPaused = !$0 }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .tint(.pulseGood)
                .controlSize(.mini)
                .labelsHidden()
                .help(store.isPaused ? "恢复剪贴板捕获" : "暂停剪贴板捕获")
                .accessibilityLabel(store.isPaused ? "已暂停捕获" : "捕获中")

                PanelIconButton(
                    systemName: showsPreview ? "eye" : "eye.slash",
                    helpText: showsPreview ? "隐藏选中项预览" : "显示选中项预览"
                ) {
                    withAnimation(HisCopyStyle.selection) { showsPreview.toggle() }
                }
                .opacity(showsPreview ? 1 : 0.5)
                .accessibilityLabel(showsPreview ? "隐藏预览" : "显示预览")

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
        HStack(spacing: 5) {
            Circle()
                .fill(store.isPaused ? Color.pulseCaution : Color.pulseGood)
                .frame(width: 6, height: 6)
            Text(store.isPaused ? "已暂停" : "捕获中")
                .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize, .medium))
                .foregroundStyle(.primary.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(HisCopyStyle.trackOpacity))
        )
        .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(searchFocused ? HisCopyStyle.textStrong : HisCopyStyle.textSecondary))
            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .font(HisCopyStyle.font(HisCopyStyle.rowFontSize + 1))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(HisCopyStyle.textSecondary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除搜索")
            } else {
                ShortcutKeyCap(label: "⌘F")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: HisCopyStyle.searchFieldCorner, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.16 : 0.08))
        )
        .animation(HisCopyStyle.hover, value: searchFocused)
        .help("⌘F 聚焦搜索")
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            if store.items.isEmpty {
                EmptyHistoryState(
                    title: "还没有历史",
                    subtitle: store.isPaused
                        ? "捕获已暂停，打开右上角开关后复制的内容会出现在这里"
                        : "复制文本、图片或文件后会出现在这里",
                    systemImage: store.isPaused ? "pause.circle" : "doc.on.clipboard"
                )
                .transition(.opacity.combined(with: .offset(y: -4)))
            } else {
                EmptyHistoryState(
                    title: "没有匹配的结果",
                    subtitle: "找不到包含「\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))」的条目，试试其他关键词",
                    systemImage: "magnifyingglass",
                    actionTitle: "清除搜索",
                    action: {
                        searchText = ""
                        searchFocused = false
                    }
                )
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        } else {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(item: item, number: index < 9 ? index + 1 : nil, isSelected: selection == item.id)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(store.formattedUsageSummary)
                    .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize, .medium).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
                Text("收藏免于自动清理 · 1–9 快速粘贴")
                    .font(HisCopyStyle.font(9.5))
                    .foregroundStyle(.primary.opacity(HisCopyStyle.textTertiary))
                    .lineLimit(1)
            }
            .help("收藏条目不计入自动清理；清空仍会删除全部。按 1–9 直接粘贴对应条目原文。")
            .accessibilityLabel("历史 \(store.items.count) 条，约 \(ClipboardHistoryStore.formatByteCount(store.approximateTotalBytes))")

            Spacer(minLength: 8)

            // ⌘V / Return are handled by PanelPasteShortcutGate (nonactivating panel).
            PanelActionButton(keyCap: "⌘V", title: "纯文本", disabled: selection == nil) {
                pastePlainSelected()
            }
            .help("写入无格式纯文本并向前置应用发送 ⌘V，然后关闭面板")

            PanelActionButton(keyCap: "↩", title: "粘贴原文", prominent: true, disabled: selection == nil) {
                pasteFormattedSelected()
            }
            .help("按原样写入剪贴板并向前置应用发送 ⌘V，然后关闭面板")
        }
        .padding(.horizontal, HisCopyStyle.stripHorizontalPadding)
        .padding(.vertical, HisCopyStyle.footerVerticalPadding)
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    var number: Int?
    var isSelected: Bool = false
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: HisCopyStyle.contentSpacing) {
            if let number {
                RowNumberBadge(number: number, isSelected: isSelected)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            leadingVisual
                .scaleEffect(isSelected ? HisCopyStyle.selectionScale : 1)
                .animation(HisCopyStyle.selection, value: isSelected)

            VStack(alignment: .leading, spacing: HisCopyStyle.rowInternalSpacing) {
                Text(item.textPreview)
                    .font(HisCopyStyle.font(HisCopyStyle.rowFontSize + 0.5, isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : HisCopyStyle.textStrong))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(HisCopyStyle.font(10, .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(HisCopyStyle.trackOpacity))
                        )

                    Text(HisCopyStyle.relativeTimeString(item.date))
                        .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize).monospacedDigit())
                        .foregroundStyle(.primary.opacity(HisCopyStyle.textSecondary))

                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.pulseCaution)
                            .accessibilityHidden(true)
                    }
                }
            }

            favoriteButton
        }
        .padding(.vertical, HisCopyStyle.rowVerticalPadding)
        .padding(.horizontal, 8)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.isFavorite ? AnyShapeStyle(Color.pulseCaution) : AnyShapeStyle(.primary.opacity(0.55)))
                .opacity(item.isFavorite || isHovered || isSelected ? 1 : 0)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovered || isSelected ? Color.primary.opacity(HisCopyStyle.trackOpacity) : Color.clear)
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

            // 1–9 (main row or keypad): quick paste of the Nth row.
            if let digit = Self.quickPickIndex(for: event.keyCode) {
                NotificationCenter.default.post(
                    name: .hisCopyPanelQuickPick,
                    object: nil,
                    userInfo: ["index": digit]
                )
                return nil
            }

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

    /// kVK_ANSI_1…9 → 0…8. Keypad digits stay navigation-only (8/2 move selection).
    private static func quickPickIndex(for keyCode: UInt16) -> Int? {
        let map: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        return map[keyCode]
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension Notification.Name {
    /// 1–9 pressed on the panel (userInfo["index"] = 0…8).
    static let hisCopyPanelQuickPick = Notification.Name("HisCopyPanelQuickPick")
}

#Preview {
    CenteredPanelRoot()
}
