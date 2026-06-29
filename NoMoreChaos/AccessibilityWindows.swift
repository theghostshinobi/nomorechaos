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
        // 1. Trova il PID proprietario della finestra fisica da CoreGraphics
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let windowTitle = info[kCGWindowName as String] as? String else {
            return false
        }

        // 2. Trova l'applicazione attiva corrispondente
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            return false
        }

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)

        // --- Phase 0: Se l'app è già attiva e abbiamo un titolo finestra, prova lo switch nativo tramite il menu "Window" ---
        if app.isActive && !windowTitle.isEmpty {
            if performMenuJump(appEl: appEl, windowTitle: windowTitle) {
                return true
            }
        }

        // --- Phase 1: Cerca la finestra nello Space corrente (senza attivare l'app) ---
        var targetWindow: AXUIElement?
        if let win = findAXWindow(windowID: windowID, in: appEl) {
            targetWindow = win
        } else {
            // --- Phase 2: La finestra è su un altro Space. Attiva l'app per forzare lo switch dello Space ---
            app.activate(options: [.activateIgnoringOtherApps])

            // Retry loop: attendiamo che lo Space cambi e la gerarchia AX si aggiorni
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                if let win = findAXWindow(windowID: windowID, in: appEl) {
                    targetWindow = win
                    break
                }
            }
        }

        guard let win = targetWindow else { return false }

        // Ripristina se minimizzata
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

        // Porta la finestra in evidenza
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)

        // Re-attiva per garantire il focus principale
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    /// Cerca il menu "Window" nella barra dei menu ed esegue il click sulla voce della finestra target
    private static func performMenuJump(appEl: AXUIElement, windowTitle: String) -> Bool {
        var menuBarVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menuBarVal) == .success else { return false }
        let menuBar = menuBarVal as! AXUIElement
        
        var childrenVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return false }
        
        let windowMenuTitles = ["Window", "Finestra", "Fenster", "Fenêtre", "Ventana", "Janela"]
        
        for (idx, item) in children.enumerated() {
            var titleVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleVal) == .success,
                  let title = titleVal as? String else { continue }
            
            let isWindowMenu = windowMenuTitles.contains(title) || idx == (children.count - 2)
            if isWindowMenu {
                var subMenuVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subMenuVal) == .success,
                   let subMenus = subMenuVal as? [AXUIElement],
                   let subMenu = subMenus.first {
                    
                    var menuItemsVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItemsVal) == .success,
                       let menuItems = menuItemsVal as? [AXUIElement] {
                        
                        for menuItem in menuItems {
                            var itemTitleVal: CFTypeRef?
                            if AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &itemTitleVal) == .success,
                               let itemTitle = itemTitleVal as? String {
                                
                                if itemTitle.localizedCaseInsensitiveContains(windowTitle) || windowTitle.localizedCaseInsensitiveContains(itemTitle) {
                                    AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                                    return true
                                }
                            }
                        }
                    }
                }
            }
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
