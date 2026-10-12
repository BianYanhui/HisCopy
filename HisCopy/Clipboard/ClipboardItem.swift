import Foundation

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let textPreview: String
    let date: Date

    init(id: UUID = UUID(), textPreview: String, date: Date = Date()) {
        self.id = id
        self.textPreview = textPreview
        self.date = date
    }
}
