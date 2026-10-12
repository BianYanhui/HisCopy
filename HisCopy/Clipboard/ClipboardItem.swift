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
    /// Favorites survive size/age auto-trim; still cleared by clearAll.
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        kind: ClipboardContentKind,
        textPreview: String,
        plainText: String? = nil,
        html: String? = nil,
        rtfData: Data? = nil,
        imageFileName: String? = nil,
        fileURLs: [String]? = nil,
        date: Date = Date(),
        isFavorite: Bool = false
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
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, textPreview, plainText, html, rtfData, imageFileName, fileURLs, date, isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipboardContentKind.self, forKey: .kind)
        textPreview = try c.decode(String.self, forKey: .textPreview)
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        fileURLs = try c.decodeIfPresent([String].self, forKey: .fileURLs)
        date = try c.decode(Date.self, forKey: .date)
        // Older history.json without this field still loads.
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(textPreview, forKey: .textPreview)
        try c.encodeIfPresent(plainText, forKey: .plainText)
        try c.encodeIfPresent(html, forKey: .html)
        try c.encodeIfPresent(rtfData, forKey: .rtfData)
        try c.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try c.encodeIfPresent(fileURLs, forKey: .fileURLs)
        try c.encode(date, forKey: .date)
        try c.encode(isFavorite, forKey: .isFavorite)
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

/// Retention age unit for settings (天 / 周 / 月).
enum RetentionAgeUnit: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "天"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var minValue: Int {
        switch self {
        case .day: return 3
        case .week: return 1
        case .month: return 1
        }
    }

    var maxValue: Int {
        switch self {
        case .day: return 30
        case .week: return 12
        case .month: return 3
        }
    }

    /// Approximate duration; months use 30-day calendar length.
    func duration(value: Int) -> TimeInterval {
        let clamped = min(max(value, minValue), maxValue)
        switch self {
        case .day:
            return TimeInterval(clamped) * 86_400
        case .week:
            return TimeInterval(clamped) * 86_400 * 7
        case .month:
            return TimeInterval(clamped) * 86_400 * 30
        }
    }

    func clamped(_ value: Int) -> Int {
        min(max(value, minValue), maxValue)
    }
}
