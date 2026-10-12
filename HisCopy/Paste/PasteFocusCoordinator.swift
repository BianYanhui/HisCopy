import AppKit
import ApplicationServices

/// Captures the destination app when the history panel opens.
///
/// With a `.nonactivatingPanel`, HisCopy should never become frontmost, so paste
/// usually needs no restore. This coordinator is the **fallback** when something
/// still activated us (search click edge cases, older macOS quirks, Settings open).
@MainActor
final class PasteFocusCoordinator {
    static let shared = PasteFocusCoordinator()

    private(set) var targetPID: pid_t?
    private var focusedElement: AXUIElement?

    private init() {}

    /// Call before ordering the panel front (destination should still be frontmost).
    func captureFromFrontmostApplication() {
        let front = NSWorkspace.shared.frontmostApplication
        guard let front,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
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

    /// True when the captured destination is already the frontmost app.
    var destinationIsFrontmost: Bool {
        guard let pid = targetPID else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Reactivate destination only if we are not already there.
    @discardableResult
    func restoreDestinationAppIfNeeded() -> pid_t? {
        guard let pid = targetPID else { return nil }
        let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        guard let app, !app.isTerminated else {
            clear()
            return nil
        }

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
            _ = app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                _ = app.activate()
            }
        } else {
            _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }
    }
}
