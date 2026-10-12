import AppKit
import ApplicationServices

/// Remembers the destination app (and best-effort focused AX element) when the
/// history panel opens, then restores that focus before synthesizing ⌘V.
///
/// Pattern used by clipboard managers: capture `NSWorkspace.frontmostApplication`
/// before the panel becomes key; on paste, `activateIgnoringOtherApps` (and
/// `activateAllWindows` so dialogs/key windows return), poll until that PID is
/// frontmost, optionally re-focus the AX element, then post ⌘V.
@MainActor
final class PasteFocusCoordinator {
    static let shared = PasteFocusCoordinator()

    private(set) var targetPID: pid_t?
    private var focusedElement: AXUIElement?

    private init() {}

    /// Call while the destination app is still frontmost (before panel key/orderFront).
    func captureFromFrontmostApplication() {
        let front = NSWorkspace.shared.frontmostApplication
        guard let front,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            // Keep any previously captured target (e.g. HisCopy already key).
            return
        }
        targetPID = front.processIdentifier
        focusedElement = nil

        guard AXIsProcessTrusted() else { return }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        )
        if result == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            focusedElement = (ref as! AXUIElement)
        }
    }

    func clear() {
        targetPID = nil
        focusedElement = nil
    }

    /// Hide is handled by the caller. Reactivate the captured app and try to
    /// restore its focused AX element (dialogs / text fields).
    @discardableResult
    func restoreDestinationApp() -> pid_t? {
        guard let pid = targetPID else { return nil }
        let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        guard let app, !app.isTerminated else {
            clear()
            return nil
        }

        // Already frontmost: skip re-activate (can drop first responder in Electron).
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            activate(app)
        }

        if let element = focusedElement {
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        return pid
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            // Yield from HisCopy; activateAllWindows restores sheets/dialogs as key.
            // SDK label is `from:` (ObjC: fromApplication:).
            _ = app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                _ = app.activate()
            }
        } else {
            _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }
    }
}
