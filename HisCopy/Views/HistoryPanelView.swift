import SwiftUI
import AppKit

struct HistoryPanelView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText = ""
    @State private var selection: UUID?

    private var filtered: [ClipboardItem] {
        store.filtered(search: searchText)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索历史", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4))

            Divider()

            HStack(spacing: 12) {
                Toggle(store.isPaused ? "已暂停捕获" : "捕获中", isOn: Binding(
                    get: { !store.isPaused },
                    set: { store.isPaused = !$0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button("清空") {
                    store.clearAll()
                    selection = nil
                }
                .disabled(store.items.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(store.items.isEmpty ? "尚无历史" : "无匹配结果")
                        .foregroundStyle(.secondary)
                    if store.isPaused {
                        Text("捕获已暂停")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        HistoryRow(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                store.copyToPasteboard(item)
                            }
                            .contextMenu {
                                Button("复制到剪贴板") {
                                    store.copyToPasteboard(item)
                                }
                                Button("删除", role: .destructive) {
                                    store.remove(id: item.id)
                                    if selection == item.id { selection = nil }
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let id = filtered[index].id
                            store.remove(id: id)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(store.items.count) / \(ClipboardHistoryStore.maxItems)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制所选") {
                    if let id = selection, let item = store.items.first(where: { $0.id == id }) {
                        store.copyToPasteboard(item)
                    }
                }
                .disabled(selection == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 420)
        .onChange(of: selection) { newValue in
            // Single click also copies for quick use (menu-bar UX).
            if let id = newValue, let item = store.items.first(where: { $0.id == id }) {
                store.copyToPasteboard(item)
            }
        }
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.kind == .image, let name = item.imageFileName,
                   let image = store.loadImage(named: name) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Image(systemName: item.symbolName)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.textPreview)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(item.kindLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(3)
                    Text(HistoryPanelView.timeString(item.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension HistoryPanelView {
    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

#Preview {
    HistoryPanelView()
}
