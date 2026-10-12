import Foundation
import AppKit

enum ClipboardContentKind: String, Codable, Equatable {
    case text
    case html
    case rtf
    case image
    case files
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipboardContentKind
    /// Short preview shown in the history list.
    let textPreview: String
    let plainText: String?
    let html: String?
    /// RTF bytes when kind == .rtf.
    let rtfData: Data?
    /// Relative file name under Application Support/HisCopy/media/.
    let imageFileName: String?
    let fileURLs: [String]?
    let date: Date

    init(
        id: UUID = UUID(),
        kind: ClipboardContentKind,
        textPreview: String,
        plainText: String? = nil,
        html: String? = nil,
        rtfData: Data? = nil,
        imageFileName: String? = nil,
        fileURLs: [String]? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.textPreview = textPreview
        self.plainText = plainText
        self.html = html
        self.rtfData = rtfData
        self.imageFileName = imageFileName
        self.fileURLs = fileURLs
        self.date = date
    }

    var kindLabel: String {
        switch kind {
        case .text: return "文本"
        case .html: return "HTML"
        case .rtf: return "RTF"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    var symbolName: String {
        switch kind {
        case .text: return "doc.plaintext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .rtf: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }
}
