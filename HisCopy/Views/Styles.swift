import SwiftUI
import AppKit

/// Shared visual tokens — Apple-native HIG, with spacing/motion feel inspired by
/// Pulse (Apache-2.0) panel patterns: continuous corners, spring open/close,
/// accent selection wells, keycap hints. Zero third-party; no Pulse source copied.
enum HisCopyStyle {
    static let panelMinWidth: CGFloat = 400
    static let panelMinHeight: CGFloat = 480
    /// Continuous corner used by SwiftUI chrome and AppKit contentView mask.
    static let panelCornerRadius: CGFloat = 14
    static let thumbnailSize: CGFloat = 38
    static let thumbnailCorner: CGFloat = 7
    static let symbolWellSize: CGFloat = 38
    static let symbolWellCorner: CGFloat = 9
    static let rowCorner: CGFloat = 9
    static let rowVerticalPadding: CGFloat = 7
    static let rowHorizontalInset: CGFloat = 10
    static let contentSpacing: CGFloat = 12
    static let stripHorizontalPadding: CGFloat = 14
    static let stripVerticalPadding: CGFloat = 10
    static let footerVerticalPadding: CGFloat = 10
    static let keyCapCorner: CGFloat = 5
    /// Hairline on light surfaces (Pulse PanelLight.edge idea: readable edge, not sliced).
    static let panelEdgeOpacity: Double = 0.14
    /// Soft scrim under material so wallpaper colour does not bleed through (esp. pink/red).
    static let panelScrimOpacityLight: Double = 0.72
    static let panelScrimOpacityDark: Double = 0.55

    /// Panel appear / expand (Pulse-like spring, Apple-native).
    static var panelAppear: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Selection / hover highlight motion.
    static var selection: Animation {
        .spring(response: 0.28, dampingFraction: 0.84)
    }

    /// Short hover wash.
    static var hover: Animation {
        .easeOut(duration: 0.12)
    }

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

/// Panel chrome: regular material + scrim + continuous clip + hairline.
/// Thicker than ultraThin so desktop wallpaper (pink/red etc.) does not bleed as a side band.
struct PanelChromeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HisCopyStyle.panelCornerRadius, style: .continuous)
        ZStack {
            shape.fill(scrim)
            shape.fill(.regularMaterial)
            shape
                .strokeBorder(Color.primary.opacity(HisCopyStyle.panelEdgeOpacity), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var scrim: Color {
        if colorScheme == .dark {
            return Color.black.opacity(HisCopyStyle.panelScrimOpacityDark)
        }
        // Slight cool-neutral grey (not pure white) so the panel reads as a surface.
        return Color(white: 0.96).opacity(HisCopyStyle.panelScrimOpacityLight)
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
                    .fill(.quaternary.opacity(0.65))
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
                    .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
            )
    }
}

struct EmptyHistoryState: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Compact keycap chip for footer shortcut hints (Pulse ShortcutField feel,
/// Apple system fills only).
struct ShortcutKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HisCopyStyle.keyCapCorner, style: .continuous)
                    .fill(.quaternary.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HisCopyStyle.keyCapCorner, style: .continuous)
                    .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// Rounded selection / hover wash behind a history row.
struct HistoryRowHighlight: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: HisCopyStyle.rowCorner, style: .continuous)
            .fill(fill)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }

    private var fill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}
