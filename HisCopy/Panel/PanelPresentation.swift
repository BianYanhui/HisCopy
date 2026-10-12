import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    /// 吸附 / 不吸附 or the docked edge changed in Settings.
    static let hisCopyPanelPresentationChanged = Notification.Name("HisCopyPanelPresentationChanged")
}

/// The panel's fill (Pulse's three surfaces: flat black is the default).
enum PanelAppearance: String, CaseIterable, Identifiable {
    case black, light, glass
    var id: String { rawValue }
    var label: String {
        switch self {
        case .black: "黑色"
        case .light: "浅色"
        case .glass: "玻璃"
        }
    }
    /// Pulse draws white content on black and glass, dark content on light.
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var usesGlass: Bool { self == .glass }
}

/// User-facing presentation settings: 吸附 / 不吸附, which edge, which surface.
@MainActor
final class PanelPresentation: ObservableObject {
    static let shared = PanelPresentation()

    private enum Key {
        static let docking = "panel.docking.enabled"
        static let appearance = "panel.appearance"
    }

    @Published var dockingEnabled: Bool {
        didSet {
            guard dockingEnabled != oldValue else { return }
            UserDefaults.standard.set(dockingEnabled, forKey: Key.docking)
            NotificationCenter.default.post(name: .hisCopyPanelPresentationChanged, object: nil)
        }
    }

    @Published var appearance: PanelAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Edge of the stored dock. Writing it re-docks at the same ratio.
    @Published var dockEdge: PanelEdge {
        didSet {
            guard dockEdge != oldValue, !dockEdgeSilently else { return }
            var placement = DockPlacement.load()
            placement.edge = dockEdge
            placement.save()
            NotificationCenter.default.post(name: .hisCopyPanelPresentationChanged, object: nil)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        dockingEnabled = defaults.bool(forKey: Key.docking)
        appearance = PanelAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .black
        dockEdge = DockPlacement.load().edge
    }

    /// Called by a drag that moved the dock to another edge (no re-dock round trip).
    func syncEdgeFromDrag(_ edge: PanelEdge) {
        guard dockEdge != edge else { return }
        // The drag already saved the placement and moved the window.
        dockEdgeSilently = true
        dockEdge = edge
        dockEdgeSilently = false
    }
    private var dockEdgeSilently = false
}
