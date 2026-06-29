import Cocoa
import SwiftUI

final class MapPanel: NSPanel {

    private var escapeMonitor: Any?

    // MARK: - Init
    //
    // A resizable, frosted-glass window (NOT a full-screen black overlay).
    // It sits at the normal window level so it no longer covers the app
    // switcher / HUD, and the user can move and resize (shrink) it. The
    // glass itself is drawn by MapView's VisualEffectBackground; the panel
    // stays transparent.

    convenience init() {
        let size = NSSize(width: 1100, height: 720)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: (screen.frame.width - size.width) / 2,
            y: (screen.frame.height - size.height) / 2
        )
        self.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 520, height: 380)

        // Hide the traffic-light buttons: the red close button bypasses
        // fadeOut() and would leak the Esc monitor. The map closes with Esc
        // (and resizes via its edges regardless of the title bar).
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Fade Animations

    func fadeIn() {
        // Always open centered on the ACTIVE monitor, preserving the user's
        // current size.
        setFrameOrigin(NSScreen.active.centeredOrigin(for: frame.size))

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEscapeMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        alphaValue = 1
    }

    func fadeOut() {
        removeEscapeMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    // MARK: - Escape Key

    private func installEscapeMonitor() {
        removeEscapeMonitor()   // idempotent — never stack monitors
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {          // Escape → back to HUD
                self?.removeEscapeMonitor()
                AppDelegate.switchToHUD()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let m = escapeMonitor {
            NSEvent.removeMonitor(m)
            escapeMonitor = nil
        }
    }

    override func close() {
        fadeOut()
    }

    override func performClose(_ sender: Any?) {
        fadeOut()
    }

    deinit { removeEscapeMonitor() }
}
