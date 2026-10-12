// Copyright (c) 2026 qunqin24. Licensed under the Apache License, Version 2.0.
// Adapted from Pulse (https://github.com/qunqin24/Pulse), Sources/Pulse/Panel/PanelPlacement.swift.
// Modified by HisCopy, 2026: reduced to an always-docked placement (no floating
// mode); a single `ratio` along the edge instead of horizontal/vertical ratios;
// HisCopy's own UserDefaults keys; frames computed for HisCopy's berth size;
// edge choice during a drag picks the nearest of left / right / top.
import AppKit

/// Where the docked panel lives: an edge, how far along it (0…1 of the
/// screen's visible length), and which display, named by UUID so it is found
/// again after a reboot or reconnection (Pulse `PanelScreen`).
struct DockPlacement: Equatable {
    var edge: PanelEdge
    /// 0 = top (side edges) / left (top edge); 1 = bottom / right. Pulse stores
    /// fractions rather than points so a resolution change keeps the spot.
    var ratio: CGFloat
    var displayID: String?

    private enum Key {
        static let edge = "panel.dock.edge"
        static let ratio = "panel.dock.ratio"
        static let display = "panel.dock.display"
    }

    static let `default` = DockPlacement(edge: .right, ratio: 0.5, displayID: nil)

    static func load() -> DockPlacement {
        let d = UserDefaults.standard
        let edge = PanelEdge(rawValue: d.string(forKey: Key.edge) ?? "") ?? Self.default.edge
        let ratio = d.object(forKey: Key.ratio) as? Double ?? Double(Self.default.ratio)
        return DockPlacement(
            edge: PanelEdge.selectable.contains(edge) ? edge : .right,
            ratio: min(max(CGFloat(ratio), 0), 1),
            displayID: d.string(forKey: Key.display)
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(edge.rawValue, forKey: Key.edge)
        d.set(Double(ratio), forKey: Key.ratio)
        if let displayID { d.set(displayID, forKey: Key.display) }
    }

    /// The stored display, or a sane fallback when it has been unplugged.
    func resolvedScreen() -> NSScreen? {
        PanelScreen.screen(withIdentifier: displayID) ?? PanelScreen.fallbackScreen()
    }

    // MARK: - Geometry

    /// The open berth's full size: the list body plus the flare at both ends
    /// along the run (Pulse keeps the flare inside the bounding rect).
    static func berthSize(for edge: PanelEdge, in visible: CGRect) -> CGSize {
        let run = DockLayout.bodyLength + DockLayout.flareHeight * 2
        if edge.isHorizontal {
            return CGSize(width: min(run, visible.width), height: min(DockLayout.bodyThickness, visible.height))
        }
        return CGSize(width: min(DockLayout.bodyThickness, visible.width), height: min(run, visible.height))
    }

    /// Pulse `PanelPlacement.layout(in:)`: flush to the edge of `visibleFrame`,
    /// positioned along it by `ratio`.
    func frame(on screen: NSScreen) -> CGRect {
        let visible = Self.dockableFrame(of: screen)
        let size = Self.berthSize(for: edge, in: visible)
        switch edge {
        case .left, .right:
            let x = edge == .left ? visible.minX : visible.maxX - size.width
            let y = visible.minY + (1 - ratio) * (visible.height - size.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        case .top, .bottom:
            let y = edge == .top ? visible.maxY - size.height : visible.minY
            let x = visible.minX + ratio * (visible.width - size.width)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    /// `visibleFrame`, additionally kept below the camera housing and the menu
    /// bar even when the menu bar auto-hides (then `visibleFrame` reaches the
    /// very top and a top dock would sit under the notch). v0.8.1.
    static func dockableFrame(of screen: NSScreen) -> CGRect {
        var visible = screen.visibleFrame
        var top = screen.frame.maxY - screen.safeAreaInsets.top
        if let notch = PanelScreen.notch(of: screen) {
            top = min(top, notch.minY)
        }
        if visible.maxY >= screen.frame.maxY - 1 {
            // Auto-hidden menu bar: leave its height free so it can slide in over nothing.
            top = min(top, screen.frame.maxY - NSStatusBar.system.thickness)
        }
        if visible.maxY > top {
            visible.size.height = max(top - visible.minY, 0)
        }
        return visible
    }

    /// Pulse `ratios(forRailAt:)`: inverse of `frame(on:)` for a proposed origin.
    static func ratio(forOrigin origin: CGPoint, edge: PanelEdge, size: CGSize, in visible: CGRect) -> CGFloat {
        let value: CGFloat
        if edge.isHorizontal {
            let span = visible.width - size.width
            value = span > 0 ? (origin.x - visible.minX) / span : 0.5
        } else {
            let span = visible.height - size.height
            value = span > 0 ? 1 - (origin.y - visible.minY) / span : 0.5
        }
        return min(max(value, 0), 1)
    }

    /// Edge chosen while dragging: Pulse decides the dock during the drag, not
    /// on release. HisCopy's 吸附 mode is always docked, so the nearest of the
    /// offered edges wins; the top needs the pointer within `dockDistance`
    /// (Pulse's rule), otherwise the nearer side.
    static func edge(forPointer p: CGPoint, in visible: CGRect) -> PanelEdge {
        if visible.maxY - p.y <= DockLayout.dockDistance { return .top }
        return (p.x - visible.minX) <= (visible.maxX - p.x) ? .left : .right
    }

    /// The collapsed sliver's hot zone in screen coordinates (Pulse: 20pt wide
    /// hit area over a 6 × 96 sliver, centred along the berth).
    func hotZone(for berth: CGRect) -> CGRect {
        let hit = DockLayout.collapsedHitWidth
        let len = DockLayout.collapsedHeight
        switch edge {
        case .right: return CGRect(x: berth.maxX - hit, y: berth.midY - len / 2, width: hit, height: len)
        case .left: return CGRect(x: berth.minX, y: berth.midY - len / 2, width: hit, height: len)
        case .top: return CGRect(x: berth.midX - len / 2, y: berth.maxY - hit, width: len, height: hit)
        case .bottom: return CGRect(x: berth.midX - len / 2, y: berth.minY, width: len, height: hit)
        }
    }

    /// The open body (berth minus the flare ends) — what counts as "on the panel".
    func body(for berth: CGRect) -> CGRect {
        let f = DockLayout.flareHeight
        return edge.isHorizontal ? berth.insetBy(dx: f, dy: 0) : berth.insetBy(dx: 0, dy: f)
    }
}
