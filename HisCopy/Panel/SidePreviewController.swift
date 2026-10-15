import AppKit
import SwiftUI

extension Notification.Name {
    /// Space pressed while the history panel is up (toggle side peek).
    static let hisCopyPanelToggleSpacePreview = Notification.Name("HisCopyPanelToggleSpacePreview")
}

/// Finder-style Space peek: a second nonactivating panel beside the history list.
///
/// **Toggle** (not hold): press Space to show / hide, like Quick Look. Selection
/// changes refresh the content while open. Esc / panel close / paste dismisses.
@MainActor
final class SidePreviewController {
    static let shared = SidePreviewController()

    private var window: NSPanel?
    private var model = SidePreviewModel()
    private var hideObserver: NSObjectProtocol?

    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.alphaValue > 0.05
    }

    /// Frame used by click-outside dismissal so a click on the peek is not "outside".
    var windowFrame: CGRect? {
        guard isVisible, let window else { return nil }
        return window.frame
    }

    private init() {
        hideObserver = NotificationCenter.default.addObserver(
            forName: .hisCopyHideHistoryPanel, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func toggle(item: ClipboardItem?) {
        if isVisible {
            hide()
        } else if let item {
            show(item: item)
        }
    }

    func show(item: ClipboardItem) {
        ensureWindow()
        guard let window else { return }
        model.item = item
        position(beside: historyPanelFrame(), screen: screenForPreview())
        window.alphaValue = 1
        window.orderFrontRegardless()
        withAnimation(HisCopyStyle.panelAppear) {
            model.appeared = true
        }
    }

    /// Refresh content when the list selection moves while the peek is open.
    func update(item: ClipboardItem) {
        guard isVisible else { return }
        model.item = item
        // Keep beside the history panel in case the berth moved (drag / screen change).
        if let window {
            position(beside: historyPanelFrame(), screen: screenForPreview(), animate: false)
            _ = window
        }
    }

    func hide() {
        guard let window else {
            model.appeared = false
            model.item = nil
            return
        }
        model.appeared = false
        model.item = nil
        window.orderOut(nil)
        window.alphaValue = 1
    }

    // MARK: - Window

    private func ensureWindow() {
        if window != nil { return }
        let panel = SidePreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: HisCopyStyle.sidePreviewWidth, height: HisCopyStyle.sidePreviewMinHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Distinct title so arrow/Space monitors still find the history window as "HisCopy".
        panel.title = "HisCopy Preview"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.contentViewController = NSHostingController(
            rootView: SidePreviewRootView(model: model)
        )
        window = panel
    }

    private func position(beside history: CGRect?, screen: NSScreen?, animate: Bool = true) {
        guard let window else { return }
        let screen = screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let history = history ?? CGRect(
            x: visible.midX - 200,
            y: visible.midY - 270,
            width: 400,
            height: 540
        )

        let width = HisCopyStyle.sidePreviewWidth
        let gap = HisCopyStyle.sidePreviewGap
        let height = min(
            max(history.height * 0.92, HisCopyStyle.sidePreviewMinHeight),
            visible.height - 24
        )

        let spaceRight = visible.maxX - history.maxX
        let spaceLeft = history.minX - visible.minX
        let preferLeft = preferredSideIsLeft(spaceLeft: spaceLeft, spaceRight: spaceRight)
        let useLeft: Bool = {
            if preferLeft {
                return spaceLeft >= width + gap || spaceLeft >= spaceRight
            }
            return spaceRight >= width + gap || spaceRight > spaceLeft
        }()

        let x: CGFloat
        if useLeft {
            x = max(visible.minX + 8, history.minX - gap - width)
        } else {
            x = min(visible.maxX - width - 8, history.maxX + gap)
        }
        let y = min(
            max(visible.minY + 8, history.midY - height / 2),
            visible.maxY - height - 8
        )
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if animate {
            window.setFrame(frame, display: true, animate: false)
        } else {
            window.setFrame(frame, display: true)
        }
        // Match docked berth level when history is statusBar-level.
        if let historyWindow = Self.historyPanelWindow() {
            window.level = historyWindow.level
        }
    }

    /// Prefer the inward side of a docked panel; otherwise the side with more room.
    private func preferredSideIsLeft(spaceLeft: CGFloat, spaceRight: CGFloat) -> Bool {
        if PanelPresentation.shared.dockingEnabled {
            switch PanelPresentation.shared.dockEdge {
            case .right: return true
            case .left: return false
            case .top, .bottom:
                return spaceLeft >= spaceRight
            }
        }
        return spaceLeft >= spaceRight
    }

    private func historyPanelFrame() -> CGRect? {
        Self.historyPanelWindow()?.frame
    }

    private func screenForPreview() -> NSScreen? {
        if let frame = historyPanelFrame() {
            return PanelScreen.containing(CGPoint(x: frame.midX, y: frame.midY))
                ?? NSScreen.main
        }
        return NSScreen.main
    }

    private static func historyPanelWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.title == "HisCopy", key.isVisible,
           !(key is SliverPanel) { return key }
        return NSApp.windows.first {
            $0.title == "HisCopy" && $0.isVisible && !($0 is SliverPanel)
        }
    }
}

/// Never becomes key — Space / arrows stay on the history monitors.
final class SidePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SidePreviewModel: ObservableObject {
    @Published var item: ClipboardItem?
    @Published var appeared = false
}

struct SidePreviewRootView: View {
    @ObservedObject var model: SidePreviewModel
    @ObservedObject private var presentation = PanelPresentation.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HisCopyStyle.panelCornerRadius, style: .continuous)
        Group {
            if let item = model.item {
                SidePeekPreview(item: item)
                    .padding(14)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PanelSurface(shape: shape, usesGlass: presentation.appearance.usesGlass) }
        .clipShape(shape)
        .opacity(model.appeared ? 1 : 0)
        .scaleEffect(model.appeared ? 1 : 0.97, anchor: .center)
        .environment(\.colorScheme, presentation.appearance.colorScheme)
    }
}

/// Larger Quick Look–style body for the side peek (text scrollable, image fitted).
struct SidePeekPreview: View {
    let item: ClipboardItem
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("预览")
                    .font(HisCopyStyle.font(HisCopyStyle.titleFontSize, .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(HisCopyStyle.font(HisCopyStyle.footnoteFontSize).monospacedDigit())
                    .foregroundStyle(.primary.opacity(HisCopyStyle.textTertiary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                ShortcutKeyCap(label: "空格")
                    .help("再按空格关闭预览")
            }
            content(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .id(item.id)
    }

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        if item.kind == .image, let name = item.imageFileName, let image = store.loadImage(named: name) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .files, let urls = item.fileURLs {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(urls, id: \.self) { raw in
                        Text(URL(string: raw)?.path ?? raw)
                            .font(HisCopyStyle.font(HisCopyStyle.sidePreviewFontSize))
                            .foregroundStyle(.primary.opacity(HisCopyStyle.textStrong))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                Text(previewText)
                    .font(HisCopyStyle.font(HisCopyStyle.sidePreviewFontSize))
                    .foregroundStyle(.primary.opacity(HisCopyStyle.textStrong))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewText: String {
        let full = item.plainText ?? item.textPreview
        let cap = 24_000
        return full.count > cap ? String(full.prefix(cap)) + "…" : full
    }

    private var detail: String {
        switch item.kind {
        case .image:
            if let name = item.imageFileName, let image = store.loadImage(named: name) {
                return "\(Int(image.size.width))×\(Int(image.size.height))"
            }
            return item.kindLabel
        case .files:
            return "\(item.fileURLs?.count ?? 0) 个文件"
        default:
            let text = item.plainText ?? item.textPreview
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(text.count) 字 · \(lines) 行"
        }
    }
}
