import SwiftUI

struct HistoryPanelView: View {
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索历史（占位）", text: $searchText)
                    .textFieldStyle(.plain)
                    .disabled(true)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4))

            Divider()

            List {
                Text("尚无历史")
                    .foregroundStyle(.secondary)
                Text("MVP 骨架")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}

#Preview {
    HistoryPanelView()
}
