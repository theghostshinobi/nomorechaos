import Cocoa
import SwiftUI

extension NSScreen {
    /// The monitor the user is currently on (the one containing the mouse
    /// cursor), falling back to the main screen. Used to center overlays on
    /// the ACTIVE monitor instead of an arbitrary one.
    static var active: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Frame origin that centers a window of `size` on this screen — using
    /// the screen's real midpoint (so it works on secondary monitors whose
    /// frame origin is non-zero, which the old `(width - w)/2` ignored).
    func centeredOrigin(for size: NSSize) -> NSPoint {
        // Center within the USABLE area (below the menu bar, above the Dock).
        NSPoint(x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2)
    }
}

final class HUDPanel: NSPanel {

    private var eventMonitor: Any?
    private var clickOutsideMonitor: Any?
    var navigationController: NavigationController?

    // MARK: - Init

    convenience init(size: NSSize) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: (screen.frame.width - size.width) / 2,
            y: (screen.frame.height - size.height) / 2
        )
        self.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // statusBar+1 sits above floating windows like Safari, AND above
        // full-screen apps. Without this, Safari/Chrome stay on top.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Fade Animations

    func fadeIn() {
        // Always re-center on the ACTIVE monitor (the one with the cursor),
        // using its real midpoint so multi-monitor setups don't place it
        // "somewhere random".
        setFrameOrigin(NSScreen.active.centeredOrigin(for: frame.size))

        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        installEventMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        // Guarantee opaque even if the implicit animation no-ops for a
        // background LSUIElement panel — never stuck transparent.
        alphaValue = 1

        // Delay click-outside arming so the click that opened the panel
        // (menu-bar dropdown, or a stray release after ⌘§) does NOT close it.
        // 500ms is comfortably above measured noise without feeling sticky.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.installClickOutsideMonitor()
        }
    }

    func fadeOut() {
        removeEventMonitor()
        removeClickOutsideMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    // MARK: - Local Key Event Monitor

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self = self, self.isVisible else { return event }

            // Forward to NavigationController
            if let nav = self.navigationController, nav.handleKeyDown(event) {
                return nil
            }

            // Escape → close
            if event.keyCode == 53 {
                self.fadeOut()
                return nil
            }

            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Click Outside → Close

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            let mouse = NSEvent.mouseLocation   // screen coords
            if !self.frame.contains(mouse) {
                self.fadeOut()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    deinit {
        removeEventMonitor()
        removeClickOutsideMonitor()
    }
}

// MARK: - Wizard Panel
//
// Floating glass panel that hosts the first-launch setup wizard.
final class WizardPanel: NSPanel {
    convenience init() {
        let size = NSSize(width: 560, height: 470)
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        setFrameOrigin(NSScreen.active.centeredOrigin(for: size))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
