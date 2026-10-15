// Copyright (c) 2026 qunqin24. Licensed under the Apache License, Version 2.0.
// Visual tokens copied from Pulse (https://github.com/qunqin24/Pulse):
// Sources/Pulse/Panel/UsageDetailCard.swift (`DetailCardLayout` type scale,
// padding, spacing, corner radius, `.primary` opacity hierarchy, rounded fonts),
// UsageDockView.swift (selection scale / springs), UsageTint.swift (status colours).
// Modified by HisCopy, 2026: tokens mapped onto HisCopy's history list (rows,
// keycaps, search field, buttons); HisCopy-specific components added.
import SwiftUI
import AppKit

/// Shared visual tokens — Pulse's panel language applied to HisCopy.
enum HisCopyStyle {
    static let panelMinWidth: CGFloat = 400
    static let panelMinHeight: CGFloat = 480
    /// Pulse `DetailCardLayout.cornerRadius` (ring outer edge, 20pt at standard size).
    static let panelCornerRadius: CGFloat = 20
    static let thumbnailSize: CGFloat = 30
    static let thumbnailCorner: CGFloat = 7
    static let symbolWellSize: CGFloat = 30
    static let rowCorner: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 7
    static let rowHorizontalInset: CGFloat = 8
    /// Pulse `rowInternalSpacing` 7 / `contentSpacing` 14.
    static let contentSpacing: CGFloat = 10
    static let rowInternalSpacing: CGFloat = 4
    /// Pulse `DetailCardLayout.padding` 18.
    static let stripHorizontalPadding: CGFloat = 18
    static let stripVerticalPadding: CGFloat = 10
    static let footerVerticalPadding: CGFloat = 12
    static let headerTopPadding: CGFloat = 14
    static let headerBottomPadding: CGFloat = 10
    static let searchFieldCorner: CGFloat = 10
    static let keyCapCorner: CGFloat = 5
    /// Space-key side peek (v0.8.9); larger than a list row, not fullscreen.
    static let sidePreviewWidth: CGFloat = 360
    static let sidePreviewMinHeight: CGFloat = 320
    static let sidePreviewGap: CGFloat = 12
    static let sidePreviewFontSize: CGFloat = 14
    /// Pulse rail selection scale.
    static let selectionScale: CGFloat = 1.06

    // Pulse type scale (`DetailCardLayout`), all `.rounded`.
    static let titleFontSize: CGFloat = 14
    static let rowFontSize: CGFloat = 12
    static let footnoteFontSize: CGFloat = 11

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // Pulse's `.primary` opacity hierarchy.
    static let textStrong: Double = 0.9
    static let textSecondary: Double = 0.45
    static let textTertiary: Double = 0.4
    /// Pulse progress track / chip fill.
    static let trackOpacity: Double = 0.12

    /// Pulse berth open/close.
    static var panelAppear: Animation { .spring(response: 0.32, dampingFraction: 0.86) }
    /// Pulse selection.
    static var selection: Animation { .spring(response: 0.28, dampingFraction: 0.84) }
    /// Pulse hover wash.
    static var hover: Animation { .easeOut(duration: 0.2) }
    static var contentTransition: Animation { .spring(response: 0.5, dampingFraction: 0.85) }

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

extension Color {
    // Pulse `UsageTint` colours, each with a deeper twin for the light panel.
    static let pulseGood = usage(dark: (0.00, 0.90, 0.55), light: (0.00, 0.58, 0.35))
    static let pulseCaution = usage(dark: (1.00, 0.76, 0.15), light: (0.76, 0.49, 0.00))
    static let pulseWarning = usage(dark: (1.00, 0.31, 0.26), light: (0.87, 0.22, 0.17))

    private static func usage(
        dark: (Double, Double, Double),
        light: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (red, green, blue) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        })
    }
}

/// Centered (不吸附) panel root: Pulse surface in a continuous rounded rect.
struct CenteredPanelRoot: View {
    @ObservedObject private var presentation = PanelPresentation.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HisCopyStyle.panelCornerRadius, style: .continuous)
        HistoryPanelView(docked: false)
            .background { PanelSurface(shape: shape, usesGlass: presentation.appearance.usesGlass) }
            .clipShape(shape)
            .environment(\.colorScheme, presentation.appearance.colorScheme)
    }
}

/// Leading glyph for a row: Pulse draws marks bare, in `.primary` 0.75.
struct SymbolWell: View {
    let systemName: String
    var size: CGFloat = HisCopyStyle.symbolWellSize
    var isSelected: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.primary.opacity(isSelected ? HisCopyStyle.textStrong : 0.75))
            .frame(width: size, height: size)
            .background(
                Circle().fill(Color.primary.opacity(isSelected ? HisCopyStyle.trackOpacity : 0.06))
            )
    }
}

struct ThumbnailImage: View {
    let image: NSImage
    var size: CGFloat = HisCopyStyle.thumbnailSize
    var isSelected: Bool = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: HisCopyStyle.thumbnailCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HisCopyStyle.thumbnailCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.35 : HisCopyStyle.trackOpacity), lineWidth: 1)
            )
    }
}

/// Empty / no-result state in Pulse's card language: a mark in a track-fill
/// circle, a rounded semibold title, a quiet subtitle, optional capsule action.
struct EmptyHistoryState: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.primary.opacity(HisCopyStyle.trackOpacity)))
                .padding(.bottom, 4)
            Text(title)
                .font(HisCopyStyle.font(HisCopyStyle.titleFontSize, .semibold))
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize))
                    .foregroundStyle(.primary.opacity(HisCopyStyle.textSecondary))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 36)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(HisCopyStyle.font(HisCopyStyle.rowFontSize, .semibold))
                        .foregroundStyle(.primary.opacity(HisCopyStyle.textStrong))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(HisCopyStyle.trackOpacity)))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Keycap chip (Pulse chip: `.primary` 0.12 fill, footnote medium at 0.5).
struct ShortcutKeyCap: View {
    let label: String
    var inverted = false

    var body: some View {
        Text(label)
            .font(HisCopyStyle.font(10, .semibold).monospacedDigit())
            .foregroundStyle(inverted ? AnyShapeStyle(Color.black.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.5)))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HisCopyStyle.keyCapCorner, style: .continuous)
                    .fill(inverted ? Color.black.opacity(0.10) : Color.primary.opacity(HisCopyStyle.trackOpacity))
            )
            .accessibilityHidden(true)
    }
}

/// 1–9 quick-pick badge on the first nine rows.
struct RowNumberBadge: View {
    let number: Int
    var isSelected = false

    var body: some View {
        Text("\(number)")
            .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize, .medium).monospacedDigit())
            .foregroundStyle(.primary.opacity(isSelected ? HisCopyStyle.textStrong : HisCopyStyle.textTertiary))
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

/// Compact icon toolbar button used in the history header.
struct PanelIconButton: View {
    let systemName: String
    let helpText: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(disabled ? 0.25 : (hovered ? HisCopyStyle.textStrong : 0.55)))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovered && !disabled ? HisCopyStyle.trackOpacity : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(helpText)
        .onHover { h in withAnimation(HisCopyStyle.hover) { hovered = h } }
    }
}

/// Pulse-style capsule action: neutral chip, or the prominent white-on-black pill.
struct PanelActionButton: View {
    let keyCap: String
    let title: String
    var prominent = false
    var disabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ShortcutKeyCap(label: keyCap, inverted: prominent && colorScheme == .dark)
                Text(title)
                    .font(HisCopyStyle.font(HisCopyStyle.rowFontSize, .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(fill))
            .contentShape(Capsule(style: .continuous))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { h in withAnimation(HisCopyStyle.hover) { hovered = h } }
    }

    private var fill: Color {
        if prominent { return Color.primary.opacity(hovered ? 1 : 0.9) }
        return Color.primary.opacity(hovered ? 0.18 : HisCopyStyle.trackOpacity)
    }

    private var foreground: Color {
        prominent ? (colorScheme == .dark ? .black : .white) : Color.primary.opacity(HisCopyStyle.textStrong)
    }
}

/// Selection / hover wash behind a history row (Pulse track fill).
struct HistoryRowHighlight: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: HisCopyStyle.rowCorner, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? HisCopyStyle.trackOpacity : (isHovered ? 0.06 : 0)))
    }
}
