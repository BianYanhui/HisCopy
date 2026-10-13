// Copyright (c) 2026 qunqin24. Licensed under the Apache License, Version 2.0.
// Docking behaviour adapted from Pulse (https://github.com/qunqin24/Pulse):
// Sources/Pulse/Panel/FloatingPanelController.swift (drag in the window with a
// grab offset, screen under the pointer, dock decided during the drag),
// PanelPointerWatcher.swift (pointer sampled on a `.common`-mode timer instead
// of enter/exit events) and UsageDockView.swift (berth open/close spring 0.32/0.86,
// contents fade 0.18 delayed 0.12 in / 0.10 out).
// Modified by HisCopy, 2026: rewritten around HisCopy's nonactivating history
// panel, paste hotkey gate and focus coordinator; hover peek vs. hotkey open;
// the sliver hot zone is tested from the sampler rather than a tracking area.
// v0.8.1: separate draggable sliver window; flicker-free key handoff on paste.
import AppKit
import SwiftUI

/// Observable state the docked SwiftUI root draws from.
@MainActor
final class DockedPanelModel: ObservableObject {
    @Published var edge: PanelEdge = .right
    @Published var isOpen = false
    @Published var berthSize: CGSize = .zero
}

/// Owns the 吸附 (docked) presentation of the history panel.
///
/// Two windows (v0.8.1): a small always-visible sliver window on the edge
/// (Pulse's 6 × 96 sliver inside a 20pt hit zone — it can be dragged, and it
/// stays put while the panel comes and goes), and the berth window, ordered in
/// only while the panel is out. Ordering the berth out hands keyboard focus
/// back to the destination app with nothing on screen changing, because the
/// sliver window under it is already drawing the same sliver.
@MainActor
final class DockedPanelController {
    static let shared = DockedPanelController()

    enum State { case collapsed, peeking, open }

    let model = DockedPanelModel()
    private(set) var window: HistoryPanel?
    private var sliver: NSPanel?
    private(set) var state: State = .collapsed
    private var placement = DockPlacement.load()
    private var timer: Timer?
    private var outsideSince: Date?
    private var hoverSince: Date?
    private var keyObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?
    /// Bumped on every open/close so a stale "order out after the spring" is ignored.
    private var transitionToken = 0

    // Drag (Pulse FloatingPanel.sendEvent: begin / carry / finish).
    private var isDragging = false
    private var grabOffset: CGPoint = .zero

    /// AppDelegate hooks: install/teardown Esc + click-outside monitors.
    var installDismissMonitors: (() -> Void)?
    var tearDownDismissMonitors: (() -> Void)?

    /// Pulse PanelPointerWatcher interval is 0.15s for leaving; the sliver is
    /// tested on the same tick, a little faster so the reveal feels immediate.
    private static let sampleInterval: TimeInterval = 0.05
    /// Hover must rest this long on the sliver before it reveals, so a press
    /// that starts a sliver drag wins over hover.
    private static let hoverDwell: TimeInterval = 0.15
    /// Grace before a hover peek slides back once the pointer has left.
    private static let leaveGrace: TimeInterval = 0.25
    /// Berth spring settles in about this long; the window is ordered out after.
    private static let closeSettle: TimeInterval = 0.34

    var isInstalled: Bool { window != nil }
    var isOpenOrPeeking: Bool { state != .collapsed }

    private init() {}

    // MARK: - Lifecycle

    func install() {
        guard window == nil else { return }
        placement = DockPlacement.load()
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 588),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.contentViewController = NSHostingController(rootView: DockedPanelRootView(model: model))
        window = panel

        let sliverPanel = SliverPanel(
            contentRect: NSRect(x: 0, y: 0, width: DockLayout.collapsedHitWidth, height: DockLayout.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(sliverPanel)
        sliverPanel.contentViewController = NSHostingController(rootView: DockSliverView(model: model))
        sliver = sliverPanel

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowBecameKey() }
        }
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }

        state = .collapsed
        model.isOpen = false
        relayout()
        sliverPanel.orderFrontRegardless()
        startSampling()
    }

    private func configure(_ panel: NSPanel) {
        panel.title = "HisCopy"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Pulse draws no window shadow on the docked rail; the berth fuses with the edge.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
    }

    func uninstall() {
        stopSampling()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        keyObserver = nil
        screensObserver = nil
        if state == .open { tearDownDismissMonitors?() }
        PanelPasteShortcutGate.shared.reset()
        window?.orderOut(nil)
        sliver?.orderOut(nil)
        window = nil
        sliver = nil
        state = .collapsed
    }

    /// Placement changed in Settings, or a display came/went: re-dock in place.
    func reloadPlacement() {
        placement = DockPlacement.load()
        relayout()
    }

    private func relayout() {
        // Multi-monitor: the stored display, or the pointer's / main screen if it is gone.
        // A missing display is not overwritten: the old UUID is kept so the
        // panel returns there when it is plugged back in; a drag re-records it.
        guard let screen = placement.resolvedScreen() else { return }
        apply(frame: placement.frame(on: screen))
    }

    private func apply(frame: CGRect) {
        if model.edge != placement.edge { model.edge = placement.edge }
        model.berthSize = frame.size
        window?.setFrame(frame, display: true)
        sliver?.setFrame(placement.hotZone(for: frame), display: true)
        // Pulse: `.statusBar` for horizontal docks, `.floating` otherwise.
        let level: NSWindow.Level = placement.edge.isHorizontal ? .statusBar : .floating
        window?.level = level
        sliver?.level = level
    }

    // MARK: - Hotkey / dismiss

    /// ⇧⌘V in docked mode: pop out from the dock (or retract if already open).
    ///
    /// "Showing" means the berth is on screen *and* sprung open — not merely
    /// `state == .open` (that lied after paste/orderOut) and not a mid-close
    /// spring with `isOpen == false`.
    func toggleFromHotKey() {
        let showing = isBerthShowing
        HotKeyTrace.line(
            "docked toggle showing=\(showing) state=\(state) visible=\(window?.isVisible == true) isOpen=\(model.isOpen)"
        )
        if showing {
            retract()
        } else {
            // Heal any half-closed bookkeeping before opening.
            if state != .collapsed || model.isOpen {
                tearDownDismissMonitors?()
                PanelPasteShortcutGate.shared.reset()
                state = .collapsed
                outsideSince = nil
                hoverSince = nil
                transitionToken += 1
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { model.isOpen = false }
            }
            open(fromHotKey: true)
        }
    }

    /// Berth is visible and expanded (user can see the list).
    private var isBerthShowing: Bool {
        guard let window, window.isVisible, window.alphaValue > 0.05 else { return false }
        return model.isOpen && state != .collapsed
    }

    /// Order the berth window in (collapsed) and spring it open on the next tick,
    /// so SwiftUI has a collapsed frame to morph from.
    private func showBerth() {
        guard let window else { return }
        transitionToken += 1
        // Paste left alpha at 0; always restore before ordering front.
        window.alphaValue = 1
        if !window.isVisible {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { model.isOpen = false }
            window.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state != .collapsed else { return }
                withAnimation(Self.berthSpring) { self.model.isOpen = true }
            }
        } else {
            withAnimation(Self.berthSpring) { model.isOpen = true }
        }
    }

    private func open(fromHotKey: Bool) {
        guard let window else { return }
        if state == .collapsed {
            PasteFocusCoordinator.shared.captureFromFrontmostApplication()
        }
        PanelPasteShortcutGate.shared.beginArmingAfterPanelOpen()
        let wasCollapsed = state == .collapsed
        state = .open
        outsideSince = nil
        showBerth()
        // v0.8.4: Pulse keeps canBecomeKey false and only orderFrontRegardless.
        // makeKeyAndOrderFront after the first open was correlated with Carbon
        // Pressed going silent. Expand without taking key; arrows / ⌘V / Return /
        // 1–9 use monitors + temporary Carbon paste hotkeys. Clicking the list
        // or search still makes the panel key (canBecomeKey remains true).
        if fromHotKey {
            window.orderFrontRegardless()
            HotKeyTrace.line("docked open fromHotKey (no makeKey) frame=\(NSStringFromRect(window.frame))")
        }
        installDismissMonitors?()
        if wasCollapsed {
            NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
        }
    }

    /// Hover: slide out without taking key, so typing still goes to the destination.
    private func peek() {
        guard state == .collapsed else { return }
        PasteFocusCoordinator.shared.captureFromFrontmostApplication()
        state = .peeking
        outsideSince = nil
        showBerth()
        NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
    }

    /// Click on the sliver (no drag): open it as if by ⇧⌘V.
    func sliverClicked() {
        guard state != .open else { return }
        open(fromHotKey: true)
    }

    /// A click inside a peeking panel makes it key: from then on it is "in use"
    /// and stays out until Esc / click-outside / paste / ⇧⌘V.
    private func windowBecameKey() {
        guard state == .peeking else { return }
        open(fromHotKey: false)
    }

    /// Slide back to the sliver (Esc, click outside, ⇧⌘V again, pointer left a peek).
    /// The berth window is ordered out once the spring has settled; the sliver
    /// window underneath is identical, so nothing visibly disappears.
    func retract() {
        guard state != .collapsed else { return }
        if state == .open { tearDownDismissMonitors?() }
        PanelPasteShortcutGate.shared.reset()
        state = .collapsed
        outsideSince = nil
        hoverSince = nil
        transitionToken += 1
        let token = transitionToken
        withAnimation(Self.berthSpring) { model.isOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSettle) { [weak self] in
            guard let self, self.transitionToken == token, self.state == .collapsed else { return }
            self.window?.orderOut(nil)
            // After the berth has resigned key — re-bind Carbon hotkey.
            GlobalHotKeyManager.shared.reregister()
        }
    }

    /// Paste path: the synthetic ⌘V must reach the destination, so key goes
    /// back *now*. The berth window is made transparent and ordered out in one
    /// step (no hide/re-show), and the sliver window — never hidden — is what
    /// remains, so there is no flash.
    func retractForPaste() {
        if state == .open { tearDownDismissMonitors?() }
        PanelPasteShortcutGate.shared.reset()
        state = .collapsed
        outsideSince = nil
        hoverSince = nil
        transitionToken += 1
        guard let window else { return }
        window.alphaValue = 0
        window.orderOut(nil)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { model.isOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            GlobalHotKeyManager.shared.reregister()
        }
    }

    // MARK: - Pointer sampling (Pulse PanelPointerWatcher)

    private func startSampling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Keep sampling while menus or other modal run loops are up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let window, !isDragging else { return }
        let p = NSEvent.mouseLocation
        switch state {
        case .collapsed:
            // A press means a drag (of the sliver or of something else) — never reveal.
            guard NSEvent.pressedMouseButtons == 0,
                  let zone = sliver?.frame, zone.contains(p) else {
                hoverSince = nil
                return
            }
            if let since = hoverSince {
                if Date().timeIntervalSince(since) >= Self.hoverDwell {
                    hoverSince = nil
                    peek()
                }
            } else {
                hoverSince = Date()
            }
        case .peeking:
            if window.isKeyWindow { open(fromHotKey: false); return }
            let inside = placement.body(for: window.frame).insetBy(dx: -8, dy: -8).contains(p)
            if inside || NSEvent.pressedMouseButtons != 0 {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) >= Self.leaveGrace { retract() }
            } else {
                outsideSince = Date()
            }
        case .open:
            break
        }
    }

    // MARK: - Drag (Pulse FloatingPanel.sendEvent mechanics)

    func beginDrag() {
        guard let window else { return }
        isDragging = true
        hoverSince = nil
        let p = NSEvent.mouseLocation
        grabOffset = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
    }

    func carryDrag() {
        guard isDragging else { return }
        let p = NSEvent.mouseLocation
        // Screen under the pointer, so a drag can carry the dock to another display.
        guard let screen = PanelScreen.containing(p) ?? placement.resolvedScreen() else { return }
        let visible = DockPlacement.dockableFrame(of: screen)
        let edge = DockPlacement.edge(forPointer: p, in: visible)
        let size = DockPlacement.berthSize(for: edge, in: visible)
        let origin: CGPoint
        if edge == placement.edge {
            origin = CGPoint(x: p.x - grabOffset.x, y: p.y - grabOffset.y)
        } else {
            // Changing edge turns the berth; centre it on the pointer and re-grab.
            origin = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
            grabOffset = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        placement.edge = edge
        placement.ratio = DockPlacement.ratio(forOrigin: origin, edge: edge, size: size, in: visible)
        placement.displayID = PanelScreen.identifier(of: screen)
        apply(frame: placement.frame(on: screen))
    }

    func finishDrag() {
        guard isDragging else { return }
        isDragging = false
        placement.save()
        PanelPresentation.shared.syncEdgeFromDrag(placement.edge)
    }

    // MARK: - Motion (Pulse UsageDockView)

    static let berthSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

/// The sliver's own window: never key, so clicking or dragging it never takes
/// keyboard focus from the destination app.
final class SliverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pulse's collapsed sliver (the berth at openness 0) in its 20pt hit zone.
struct DockSliverView: View {
    @ObservedObject var model: DockedPanelModel
    @ObservedObject private var presentation = PanelPresentation.shared

    var body: some View {
        let edge = model.edge
        ZStack(alignment: alignment(for: edge)) {
            // Pulse `PanelGlass.claim`: a fill no one can see gives the window the press.
            PanelGlass.claim
            PanelSurface(
                shape: DockBerthShape(edge: edge, openness: 0),
                usesGlass: presentation.appearance.usesGlass,
                screenEdge: edge.screenSide
            )
            .frame(
                width: edge.isHorizontal ? DockLayout.collapsedHeight : DockLayout.collapsedWidth,
                height: edge.isHorizontal ? DockLayout.collapsedWidth : DockLayout.collapsedHeight
            )
        }
        .overlay(SliverDragHandle())
        .environment(\.colorScheme, presentation.appearance.colorScheme)
        .help("悬停展开 · 点击打开 · 拖动以移动")
    }

    private func alignment(for edge: PanelEdge) -> Alignment {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}

/// Press-and-move on the sliver drags the dock; a press without movement is a click.
struct SliverDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {}

    final class HandleView: NSView {
        private var downAt: CGPoint?
        private var dragging = false
        /// Movement before a press becomes a drag.
        private static let threshold: CGFloat = 3

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            downAt = NSEvent.mouseLocation
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downAt else { return }
            let p = NSEvent.mouseLocation
            if !dragging, hypot(p.x - downAt.x, p.y - downAt.y) >= Self.threshold {
                dragging = true
                NSCursor.closedHand.push()
                DockedPanelController.shared.beginDrag()
            }
            if dragging { DockedPanelController.shared.carryDrag() }
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                NSCursor.pop()
                DockedPanelController.shared.finishDrag()
            } else {
                DockedPanelController.shared.sliverClicked()
            }
            downAt = nil
            dragging = false
        }
    }
}

/// Nonactivating floating panel: can be key for search/arrows/paste shortcuts
/// without activating HisCopy, so the original dialog keeps system focus.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI root

/// The docked panel: Pulse's berth (sliver ↔ open body, one shape morphing)
/// filled with `PanelSurface`, HisCopy's history list on top.
struct DockedPanelRootView: View {
    @ObservedObject var model: DockedPanelModel
    @ObservedObject private var presentation = PanelPresentation.shared

    var body: some View {
        let edge = model.edge
        let open = model.isOpen
        let full = model.berthSize
        ZStack(alignment: alignment(for: edge)) {
            Color.clear
            PanelSurface(
                shape: DockBerthShape(edge: edge, openness: open ? 1 : 0),
                usesGlass: presentation.appearance.usesGlass,
                screenEdge: edge.screenSide
            )
            .frame(
                width: open ? full.width : collapsedSize(edge).width,
                height: open ? full.height : collapsedSize(edge).height
            )
            .animation(DockedPanelController.berthSpring, value: open)

            HistoryPanelView(docked: true)
                .frame(width: bodySize(edge, full).width, height: bodySize(edge, full).height)
                .frame(width: full.width, height: full.height)
                .opacity(open ? 1 : 0)
                // Pulse: contents fade in after the berth has mostly grown, out at once.
                .animation(open ? .easeOut(duration: 0.18).delay(0.12) : .easeOut(duration: 0.10), value: open)
                .allowsHitTesting(open)
        }
        .frame(width: full.width, height: full.height)
        .environment(\.colorScheme, presentation.appearance.colorScheme)
    }

    private func alignment(for edge: PanelEdge) -> Alignment {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func collapsedSize(_ edge: PanelEdge) -> CGSize {
        edge.isHorizontal
            ? CGSize(width: DockLayout.collapsedHeight, height: DockLayout.collapsedWidth)
            : CGSize(width: DockLayout.collapsedWidth, height: DockLayout.collapsedHeight)
    }

    private func bodySize(_ edge: PanelEdge, _ full: CGSize) -> CGSize {
        let f = DockLayout.flareHeight
        return edge.isHorizontal
            ? CGSize(width: max(full.width - f * 2, 0), height: full.height)
            : CGSize(width: full.width, height: max(full.height - f * 2, 0))
    }
}

/// Grab handle for moving the dock. Handles its own mouse events (Pulse takes
/// them in `sendEvent`; a dedicated handle keeps buttons in the header safe).
struct DockDragHandle: NSViewRepresentable {
    let docked: Bool

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.docked = docked
        return v
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.docked = docked
    }

    final class HandleView: NSView {
        var docked = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            if docked {
                MainActor.assumeIsolated { DockedPanelController.shared.beginDrag() }
                NSCursor.closedHand.push()
            } else {
                window?.performDrag(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard docked else { return }
            MainActor.assumeIsolated { DockedPanelController.shared.carryDrag() }
        }

        override func mouseUp(with event: NSEvent) {
            guard docked else { return }
            NSCursor.pop()
            MainActor.assumeIsolated { DockedPanelController.shared.finishDrag() }
        }
    }
}
