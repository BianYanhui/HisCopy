import Foundation
import AppKit
import Combine

/// In-memory + Application Support JSON history (FIFO, max 200).
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    static let maxItems = 200
    static let pauseKey = "HisCopy.capturePaused"

    @Published private(set) var items: [ClipboardItem] = []
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pauseKey) }
    }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var supportDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HisCopy", isDirectory: true)
    }

    private var historyURL: URL {
        supportDir.appendingPathComponent("history.json", isDirectory: false)
    }

    var mediaDir: URL {
        supportDir.appendingPathComponent("media", isDirectory: true)
    }

    private init() {
        isPaused = UserDefaults.standard.bool(forKey: Self.pauseKey)
        ensureDirectories()
        load()
    }

    func togglePause() {
        isPaused.toggle()
    }

    func add(_ item: ClipboardItem) {
        // Deduplicate consecutive identical plain text / preview.
        if let first = items.first {
            if first.kind == item.kind,
               first.plainText == item.plainText,
               first.textPreview == item.textPreview,
               first.fileURLs == item.fileURLs {
                return
            }
        }
        items.insert(item, at: 0)
        trimIfNeeded()
        save()
    }

    func remove(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            removeMedia(for: item)
        }
        items.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        for item in items {
            removeMedia(for: item)
        }
        items.removeAll()
        save()
    }

    func filtered(search: String) -> [ClipboardItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.textPreview.localizedCaseInsensitiveContains(q)
                || ($0.plainText?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.fileURLs?.joined(separator: " ").localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Write item back to the system pasteboard (no Accessibility paste).
    func copyToPasteboard(_ item: ClipboardItem) {
        ClipboardMonitor.shared.markNextWriteAsSelf()
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text:
            if let text = item.plainText {
                pb.setString(text, forType: .string)
            }
        case .html:
            if let html = item.html {
                pb.setString(html, forType: .html)
            }
            if let text = item.plainText {
                pb.setString(text, forType: .string)
            }
        case .rtf:
            if let rtf = item.rtfData {
                pb.setData(rtf, forType: .rtf)
            }
            if let text = item.plainText {
                pb.setString(text, forType: .string)
            }
        case .image:
            if let name = item.imageFileName {
                let url = mediaDir.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    pb.writeObjects([image])
                    if let tiff = image.tiffRepresentation {
                        pb.setData(tiff, forType: .tiff)
                    }
                    if let png = pngData(from: image) {
                        pb.setData(png, forType: .png)
                    }
                }
            }
        case .files:
            if let paths = item.fileURLs {
                let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                pb.writeObjects(urls)
            }
        }

        // Marker so our monitor ignores this write-back.
        pb.setString("1", forType: NSPasteboard.PasteboardType(ClipboardMonitor.selfWriteType))
    }

    func saveImageData(_ data: Data, id: UUID) -> String? {
        ensureDirectories()
        let name = "\(id.uuidString).png"
        let url = mediaDir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func loadImage(named name: String) -> NSImage? {
        let url = mediaDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Persistence

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    private func load() {
        guard fileManager.fileExists(atPath: historyURL.path),
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? decoder.decode([ClipboardItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        ensureDirectories()
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func trimIfNeeded() {
        while items.count > Self.maxItems {
            if let last = items.popLast() {
                removeMedia(for: last)
            }
        }
    }

    private func removeMedia(for item: ClipboardItem) {
        guard let name = item.imageFileName else { return }
        let url = mediaDir.appendingPathComponent(name)
        try? fileManager.removeItem(at: url)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
