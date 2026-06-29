import Cocoa
import ApplicationServices

// ============================================================================
// MARK: - Accessibility: raise a specific window
//
// Window ENUMERATION is done elsewhere via CGWindowList(.optionAll), because
// the Accessibility API's kAXWindows only returns windows on the CURRENT Space
// — useless for a multi-desktop workflow. But Accessibility IS the only public
// way to bring ONE specific window to the front on jump (CGWindowList can list
// but not raise). So this file does just that: given a CGWindowID, find the
// matching AX window and raise it. Needs the macOS Accessibility permission
// (granted in the setup wizard), the same one Rectangle/Magnet use; callers
// fall back to a plain app activation when it isn't available.
// ============================================================================

// Private CoreGraphics/HIServices bridge: maps an AXUIElement window back to its
// CGWindowID. Used by every serious window manager (yabai, etc.) to correlate
// AX windows with CGWindowList entries.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

enum AXWindows {
    /// Bring ONE specific window to the front (un-minimizing if needed) and
    /// activate its app. Returns false if the window could not be located via
    /// Accessibility (caller falls back to a plain app activation).
    @discardableResult
    static func raise(windowID: CGWindowID, bundleID: String?) async -> Bool {
        // First pass narrows to the owning app (fast); second pass searches
        // everything in case the bundleID hint was stale.
        if let bundleID, await raiseInApps(windowID: windowID, matching: bundleID) { return true }
        return await raiseInApps(windowID: windowID, matching: nil)
    }

    private static func raiseInApps(windowID: CGWindowID, matching bundleID: String?) async -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory,
                  !app.isTerminated
            else { continue }
            if let bundleID, app.bundleIdentifier != bundleID { continue }

            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.3)

            // --- Phase 1: Try to find the window on the CURRENT Space (no activation) ---
            var targetWindow: AXUIElement?
            if let win = findAXWindow(windowID: windowID, in: appEl) {
                targetWindow = win
            } else if bundleID != nil {
                // --- Phase 2: Window not on current Space. Activate the app so macOS
                // switches to the Space where its windows live (requires the system
                // preference "When switching to an application, switch to a Space with
                // open windows for the application" to be enabled). ---
                app.activate(options: [.activateIgnoringOtherApps])

                // Retry loop: wait for the Space switch and AX list to update.
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    if let win = findAXWindow(windowID: windowID, in: appEl) {
                        targetWindow = win
                        break
                    }
                }
            }

            guard let win = targetWindow else { continue }

            // Unminimize the window first
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

            // Raise the window in-place — do NOT reposition it.
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)

            // Re-activate the application to guarantee front-most key focus
            app.activate(options: [.activateIgnoringOtherApps])
            return true
        }
        return false
    }

    /// Searches an app's AX window list for one matching the given CGWindowID.
    private static func findAXWindow(windowID: CGWindowID, in appEl: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID {
                return win
            }
        }
        return nil
    }
}
