import Foundation
import AppKit
import Combine

/// In-memory + Application Support JSON history with size/age retention.
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    static let pauseKey = "HisCopy.capturePaused"
    static let maxStorageMBKey = "HisCopy.maxStorageMB"
    static let retentionAgeUnitKey = "HisCopy.retentionAgeUnit"
    static let retentionAgeValueKey = "HisCopy.retentionAgeValue"

    /// Preset storage caps (MB) shown in Settings.
    static let storageMBPresets: [Int] = [10, 25, 50, 100, 200, 500]
    static let defaultMaxStorageMB = 100
    static let defaultAgeUnit: RetentionAgeUnit = .day
    static let defaultAgeValue = 30

    @Published private(set) var items: [ClipboardItem] = []
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pauseKey) }
    }

    /// Max total history footprint in megabytes (JSON payload + media files).
    @Published var maxStorageMB: Int {
        didSet {
            let clamped = Self.clampStorageMB(maxStorageMB)
            if clamped != maxStorageMB {
                maxStorageMB = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.maxStorageMBKey)
            trimIfNeeded()
            save()
        }
    }

    @Published var retentionAgeUnit: RetentionAgeUnit {
        didSet {
            UserDefaults.standard.set(retentionAgeUnit.rawValue, forKey: Self.retentionAgeUnitKey)
            // Do not clamp retentionAgeValue here — cross-property didSet during
            // SwiftUI Picker/Stepper paint can expose a one-frame out-of-range
            // Stepper binding and crash Settings on open. Use setRetentionAgeUnit(_:)
            // or the Settings bindings which clamp before the range changes.
            trimIfNeeded()
            save()
        }
    }

    @Published var retentionAgeValue: Int {
        didSet {
            let clamped = retentionAgeUnit.clamped(retentionAgeValue)
            if clamped != retentionAgeValue {
                retentionAgeValue = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.retentionAgeValueKey)
            trimIfNeeded()
            save()
        }
    }

    /// Switch unit after clamping value so SwiftUI Stepper never sees value ∉ range.
    func setRetentionAgeUnit(_ unit: RetentionAgeUnit) {
        let clamped = unit.clamped(retentionAgeValue)
        // For these presets the clamped value stays valid under the old unit too,
        // so assigning value first then unit keeps every intermediate frame safe.
        if retentionAgeValue != clamped {
            retentionAgeValue = clamped
        }
        if retentionAgeUnit != unit {
            retentionAgeUnit = unit
        }
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

    /// Approximate on-disk footprint: encoded item payloads + media files.
    var approximateTotalBytes: Int {
        items.reduce(0) { $0 + approximateByteSize(for: $1) }
    }

    var formattedUsageSummary: String {
        let count = items.count
        let size = Self.formatByteCount(approximateTotalBytes)
        return "\(count) 条 · 约 \(size)"
    }

    private init() {
        isPaused = UserDefaults.standard.bool(forKey: Self.pauseKey)

        let storedMB = UserDefaults.standard.object(forKey: Self.maxStorageMBKey) as? Int
        maxStorageMB = Self.clampStorageMB(storedMB ?? Self.defaultMaxStorageMB)

        let unit: RetentionAgeUnit
        if let raw = UserDefaults.standard.string(forKey: Self.retentionAgeUnitKey),
           let parsed = RetentionAgeUnit(rawValue: raw) {
            unit = parsed
        } else {
            unit = Self.defaultAgeUnit
        }
        let storedAge = UserDefaults.standard.object(forKey: Self.retentionAgeValueKey) as? Int
        let ageValue = unit.clamped(storedAge ?? Self.defaultAgeValue)

        // Assign after locals are ready so we don't touch self mid-init.
        retentionAgeUnit = unit
        retentionAgeValue = ageValue

        ensureDirectories()
        load()
        trimIfNeeded()
        save()
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

    func toggleFavorite(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isFavorite.toggle()
        save()
    }

    func setFavorite(id: UUID, _ value: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].isFavorite != value else { return }
        items[idx].isFavorite = value
        save()
    }

    /// Clears everything, including favorites.
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

    /// 仅写入无格式纯文本（用于面板内 ⌘V）。
    func copyPlainTextToPasteboard(_ item: ClipboardItem) {
        ClipboardMonitor.shared.markNextWriteAsSelf()
        let pb = NSPasteboard.general
        pb.clearContents()

        let plain: String? = {
            if let t = item.plainText, !t.isEmpty { return t }
            switch item.kind {
            case .files:
                return item.fileURLs?.joined(separator: "\n")
            case .image:
                return item.textPreview
            default:
                return item.textPreview.isEmpty ? nil : item.textPreview
            }
        }()

        if let plain {
            pb.setString(plain, forType: .string)
        }

        pb.setString("1", forType: NSPasteboard.PasteboardType(ClipboardMonitor.selfWriteType))
    }

    /// 按原样写回剪贴板（富文本/HTML/图片/文件等，用于回车粘贴）。
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

    func approximateByteSize(for item: ClipboardItem) -> Int {
        var size = 0
        if let data = try? encoder.encode(item) {
            size += data.count
        }
        if let name = item.imageFileName {
            let url = mediaDir.appendingPathComponent(name)
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? NSNumber {
                size += fileSize.intValue
            }
        }
        return size
    }

    static func formatByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    static func clampStorageMB(_ value: Int) -> Int {
        let presets = storageMBPresets
        guard !presets.isEmpty else { return defaultMaxStorageMB }
        // Snap to nearest preset so Settings Picker selection always matches a tag.
        return presets.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultMaxStorageMB
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

    /// Drop over-age then oversize items. Favorites are never auto-discarded.
    func trimIfNeeded() {
        trimByAge()
        trimBySize()
    }

    private func trimByAge() {
        let limit = retentionAgeUnit.duration(value: retentionAgeValue)
        let cutoff = Date().addingTimeInterval(-limit)
        let victims = items.filter { !$0.isFavorite && $0.date < cutoff }
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        for item in victims {
            removeMedia(for: item)
        }
        items.removeAll { victimIDs.contains($0.id) }
    }

    private func trimBySize() {
        let limitBytes = maxStorageMB * 1_048_576
        var total = approximateTotalBytes
        guard total > limitBytes else { return }

        // Oldest non-favorites first (items are newest-first).
        while total > limitBytes {
            guard let idx = items.lastIndex(where: { !$0.isFavorite }) else { break }
            let removed = items.remove(at: idx)
            total -= approximateByteSize(for: removed)
            removeMedia(for: removed)
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
