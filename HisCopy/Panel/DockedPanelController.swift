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
/// One window sits flush against the chosen edge at full berth size. Collapsed,
/// only Pulse's 6 × 96 sliver is drawn and the window ignores the mouse, so the
/// transparent rest never eats a click; the pointer sampler reveals it.
@MainActor
final class DockedPanelController {
    static let shared = DockedPanelController()

    enum State { case collapsed, peeking, open }

    let model = DockedPanelModel()
    private(set) var window: HistoryPanel?
    private(set) var state: State = .collapsed
    private var placement = DockPlacement.load()
    private var timer: Timer?
    private var outsideSince: Date?
    private var keyObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?

    // Drag (Pulse FloatingPanel.sendEvent: begin / carry / finish).
    private var isDragging = false
    private var grabOffset: CGPoint = .zero

    /// AppDelegate hooks: install/teardown Esc + click-outside monitors.
    var installDismissMonitors: (() -> Void)?
    var tearDownDismissMonitors: (() -> Void)?

    /// Pulse PanelPointerWatcher interval is 0.15s for leaving; the sliver is
    /// tested on the same tick, a little faster so the reveal feels immediate.
    private static let sampleInterval: TimeInterval = 0.08
    /// Grace before a hover peek slides back once the pointer has left.
    private static let leaveGrace: TimeInterval = 0.25

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
        panel.ignoresMouseEvents = true
        panel.contentViewController = NSHostingController(rootView: DockedPanelRootView(model: model))
        window = panel

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
        panel.orderFrontRegardless()
        startSampling()
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
        window = nil
        state = .collapsed
    }

    /// Placement changed in Settings, or a display came/went: re-dock in place.
    func reloadPlacement() {
        placement = DockPlacement.load()
        relayout()
    }

    private func relayout() {
        guard let window else { return }
        // Multi-monitor: the stored display, or the pointer's / main screen if it is gone.
        guard let screen = placement.resolvedScreen() else { return }
        // A missing display is not overwritten: the old UUID is kept so the
        // panel returns there when it is plugged back in; a drag re-records it.
        let frame = placement.frame(on: screen)
        model.edge = placement.edge
        model.berthSize = frame.size
        window.setFrame(frame, display: true)
        // Pulse: `.statusBar` for horizontal docks, `.floating` otherwise.
        window.level = placement.edge.isHorizontal ? .statusBar : .floating
    }

    // MARK: - Hotkey / dismiss

    /// ⇧⌘V in docked mode: pop out from the dock (or retract if already open).
    func toggleFromHotKey() {
        if state == .open {
            retract()
        } else {
            open(fromHotKey: true)
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
        window.ignoresMouseEvents = false
        withAnimation(Self.berthSpring) { model.isOpen = true }
        window.orderFrontRegardless()
        if fromHotKey {
            window.makeKeyAndOrderFront(nil)
            if let content = window.contentView { _ = window.makeFirstResponder(content) }
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                if let content = window.contentView { _ = window.makeFirstResponder(content) }
            }
        }
        installDismissMonitors?()
        if wasCollapsed {
            NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
        }
    }

    /// Hover: slide out without taking key, so typing still goes to the destination.
    private func peek() {
        guard let window, state == .collapsed else { return }
        PasteFocusCoordinator.shared.captureFromFrontmostApplication()
        state = .peeking
        outsideSince = nil
        window.ignoresMouseEvents = false
        withAnimation(Self.berthSpring) { model.isOpen = true }
        NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen, object: nil)
    }

    /// A click inside a peeking panel makes it key: from then on it is "in use"
    /// and stays out until Esc / click-outside / paste / ⇧⌘V.
    private func windowBecameKey() {
        guard state == .peeking else { return }
        open(fromHotKey: false)
    }

    /// Slide back to the sliver (Esc, click outside, ⇧⌘V again, pointer left a peek).
    func retract() {
        guard let window, state != .collapsed else { return }
        if state == .open { tearDownDismissMonitors?() }
        PanelPasteShortcutGate.shared.reset()
        state = .collapsed
        outsideSince = nil
        dropKey(window)
        window.ignoresMouseEvents = true
        withAnimation(Self.berthSpring) { model.isOpen = false }
    }

    /// Paste path: give key back *now* (the synthetic ⌘V must reach the
    /// destination), collapse without animation, then show the sliver again.
    func retractForPaste() {
        guard let window else { return }
        if state == .open { tearDownDismissMonitors?() }
        PanelPasteShortcutGate.shared.reset()
        state = .collapsed
        outsideSince = nil
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { model.isOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let window = self.window, self.state == .collapsed else { return }
            window.orderFrontRegardless()
        }
    }

    /// A key nonactivating panel keeps the keyboard even while another app is
    /// active; ordering it out and back hands key to the destination window.
    private func dropKey(_ window: NSWindow) {
        guard window.isKeyWindow else { return }
        window.orderOut(nil)
        window.orderFrontRegardless()
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
            // No reveal mid-click/drag of something else (e.g. a window being dragged past).
            guard NSEvent.pressedMouseButtons == 0 else { return }
            if placement.hotZone(for: window.frame).contains(p) { peek() }
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
        let p = NSEvent.mouseLocation
        grabOffset = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
    }

    func carryDrag() {
        guard isDragging, let window else { return }
        let p = NSEvent.mouseLocation
        // Screen under the pointer, so a drag can carry the dock to another display.
        guard let screen = PanelScreen.containing(p) ?? placement.resolvedScreen() else { return }
        let visible = screen.visibleFrame
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
        let frame = placement.frame(on: screen)
        if model.edge != edge { model.edge = edge }
        model.berthSize = frame.size
        window.setFrame(frame, display: true)
        window.level = edge.isHorizontal ? .statusBar : .floating
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
