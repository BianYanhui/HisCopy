import SwiftUI
import AppKit

struct HistoryPanelView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var appeared = false

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbarStrip

                Divider().opacity(0.55)

                content

                Divider().opacity(0.55)

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
        .background(.ultraThinMaterial)
        .opacity(appeared ? 1 : 0.92)
        .scaleEffect(appeared ? 1 : 0.985)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) {
                appeared = true
            }
            if selection == nil {
                selection = filtered.first?.id
            }
        }
        .onChange(of: searchText) { _ in
            if let selection, filtered.contains(where: { $0.id == selection }) { return }
            selection = filtered.first?.id
        }
    }

    /// ⌘V：无格式纯文本 → 模拟粘贴 → 关闭面板。
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            EmptyHistoryState(
                title: store.items.isEmpty ? "尚无历史" : "无匹配结果",
                subtitle: store.isPaused ? "捕获已暂停" : (store.items.isEmpty ? "复制内容后会出现在这里" : nil),
                systemImage: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
            )
        } else {
            List(selection: $selection) {
                ForEach(filtered) { item in
                    HistoryRow(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
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
            .listStyle(.inset)
            .listRowSeparator(.visible)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text("\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)

            Text("⌘V 纯文本 · ↩ 有格式")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                pastePlainSelected()
            } label: {
                Label("纯文本", systemImage: "doc.plaintext")
            }
            .controlSize(.small)
            .disabled(selection == nil)
            .keyboardShortcut("v", modifiers: .command)
            .help("写入无格式纯文本并向前置应用发送 ⌘V，然后关闭面板")

            Button {
                pasteFormattedSelected()
            } label: {
                Label("粘贴原文", systemImage: "doc.richtext")
            }
            .controlSize(.small)
            .disabled(selection == nil)
            .keyboardShortcut(.defaultAction)
            .help("按原样写入剪贴板并向前置应用发送 ⌘V，然后关闭面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: HisCopyStyle.contentSpacing) {
            leadingVisual

            VStack(alignment: .leading, spacing: 3) {
                Text(item.textPreview)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.quaternary.opacity(0.7))
                        )

                    Text(HisCopyStyle.relativeTimeString(item.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, HisCopyStyle.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kindLabel)，\(item.textPreview)")
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

#Preview {
    HistoryPanelView()
}
