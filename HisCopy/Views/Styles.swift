import SwiftUI
import AppKit

/// Shared visual tokens for a native macOS / HIG look (Notes / Spotlight / Maccy restraint).
enum HisCopyStyle {
    static let panelMinWidth: CGFloat = 380
    static let panelMinHeight: CGFloat = 460
    static let thumbnailSize: CGFloat = 36
    static let thumbnailCorner: CGFloat = 6
    static let symbolWellSize: CGFloat = 36
    static let symbolWellCorner: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 4
    static let contentSpacing: CGFloat = 10

    static let relativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    static func relativeTimeString(_ date: Date) -> String {
        relativeTime.localizedString(for: date, relativeTo: Date())
    }
}

/// Soft SF Symbol well matching system list affordances.
struct SymbolWell: View {
    let systemName: String
    var size: CGFloat = HisCopyStyle.symbolWellSize

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: HisCopyStyle.symbolWellCorner, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )
    }
}

struct ThumbnailImage: View {
    let image: NSImage
    var size: CGFloat = HisCopyStyle.thumbnailSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: HisCopyStyle.thumbnailCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HisCopyStyle.thumbnailCorner, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.6), lineWidth: 0.5)
            )
    }
}

struct EmptyHistoryState: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
