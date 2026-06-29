import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {

    // Explicit reference to the live delegate. SwiftUI's
    // @NSApplicationDelegateAdaptor does NOT set NSApp.delegate, so
    // `NSApp.delegate as? AppDelegate` returns nil and every static
    // entry point silently no-ops. We hold our own reference instead.
    static weak var shared: AppDelegate?
    private static var relaunchWatcherSpawned = false

    private var hudPanel: HUDPanel?
    private var mapPanel: MapPanel?
    private var wizardPanel: WizardPanel?
    private var navigationController: NavigationController?

    /// True while the setup wizard is on screen. Blocks ALL other panels.
    private var wizardIsActive = false

    // Carbon hotkey state (zero permissions required).
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    // Local NSEvent monitor for when the HUD is the key window.
    private var localHotkeyMonitor: Any?

    // Physical keycodes that carry "§" on Italian Apple keyboards.
    // There are TWO: kVK_ISO_Section (10) is the key next to the left
    // Shift; keycode 42 is the ù/§ key next to Return. We bind ⌘ to
    // BOTH so the hotkey fires no matter which § key the user presses.
    private let hotkeyKeyCodes: [UInt32] = [UInt32(kVK_ISO_Section), 42]

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        AppDelegate.shared = self
        KeychainHelper.migrateFromUserDefaults()
        CoreDataManager(context: PersistenceController.shared.container.viewContext)
            .purgeLegacyJunk()
        setupHUDPanel()
        setupMapPanel()
        registerGlobalHotkey()

        if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            // First launch — show ONLY the wizard after a short delay so
            // SwiftUI's run loop + NSApp are fully ready. Without this,
            // NSApp.activate / makeKeyAndOrderFront silently fail.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showWizard()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            showWizard()
        } else {
            toggleHUD()
        }
        return true
    }

    // MARK: - Accessibility Permission
    //
    // Lets NoMoreChaos enumerate EVERY window of every app (not just the front
    // one) and raise a SPECIFIC window on jump — the foundation of "same app,
    // different projects". Same permission Rectangle/Magnet use. Shows up in
    // System Settings → Privacy & Security → Accessibility.

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility prompt (no-op if already trusted).
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Clears stale TCC entries for this app so a fresh prompt registers
    /// the CURRENT binary's CDHash.  Ad-hoc signed apps get a new CDHash
    /// on every rebuild, which makes old TCC grants invisible to the
    /// running binary even though the toggle looks "ON" in System Settings.
    /// Safe to call repeatedly — no-op effect if no stale entry exists.
    static func resetStaleTCC(for service: String) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tccutil") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.nomorechaos.app"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError  = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: - Screen Recording Permission
    //
    // Reading other apps' window titles (kCGWindowName) and capturing
    // window thumbnails (CGWindowListCreateImage) BOTH require Screen
    // Recording permission on macOS 10.15+. Without it the whole app shows
    // empty lists and blank previews. We trigger the system prompt once;
    // if the user already decided, this is a harmless no-op.

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    static func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Spawns a background shell script that waits for this process to die,
    /// and then opens the application again. This is used to ensure the app
    /// relaunches after the macOS-forced relaunch for Screen Recording permission.
    static func spawnRelaunchWatcher() {
        guard !relaunchWatcherSpawned else { return }
        relaunchWatcherSpawned = true

        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundlePath
        let script = """
        (
            while kill -0 \(pid) 2>/dev/null; do
                sleep 0.5
            done
            sleep 1.2
            open "\(appPath)"
        ) &
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        try? task.run()
    }

    // MARK: - Launch at Login
    //
    // Controlled by the setup wizard (and re-runnable from the menu), so we
    // expose status + a setter instead of registering unconditionally.
    // Shows up in System Settings → General → Login Items.

    static func isLaunchAtLoginEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Applies the change and returns the ACTUAL resulting state, so callers
    /// can revert their UI if SMAppService threw.
    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("Login item toggle failed: \(error)")
        }
        return SMAppService.mainApp.status == .enabled
    }

    // MARK: - Setup Wizard

    func showWizard() {
        if wizardPanel == nil { wizardPanel = WizardPanel() }
        guard let panel = wizardPanel else { return }

        // Block every other panel while the wizard is active.
        wizardIsActive = true
        hudPanel?.fadeOut()
        mapPanel?.fadeOut()

        // Rebuild the view each time so reopening from the menu restarts at
        // step 0 (with fresh permission/login status) rather than the last
        // step the user left it on.
        let view = WizardView(onFinish: { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            self?.wizardIsActive = false
            self?.wizardPanel?.orderOut(nil)
            // Tear down the hosting view so the 1s permission poll stops.
            DispatchQueue.main.async { self?.wizardPanel?.contentView = nil }
            // Kick WindowTracker so it starts scanning immediately with the
            // freshly-granted permissions — no app restart needed.
            WindowTracker.shared.bootstrap()
        })
        panel.contentView = NSHostingView(rootView: view)

        panel.setFrameOrigin(NSScreen.active.centeredOrigin(for: panel.frame.size))

        // For an LSUIElement app, NSApp.activate alone is unreliable at
        // bringing a panel in front of other apps. We must:
        // 1. Force the panel visible with orderFrontRegardless
        // 2. Temporarily become .regular so the window server gives us focus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Revert to accessory after the next run-loop tick so the Dock icon
        // disappears again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func showWizard() {
        AppDelegate.shared?.showWizard()
    }

    // MARK: - HUD Panel Setup

    private func setupHUDPanel() {
        let panel = HUDPanel(size: NSSize(width: 860, height: 480))
        let context = PersistenceController.shared.container.viewContext
        let nav = NavigationController(context: context)

        nav.onDismiss = { [weak panel] in
            panel?.fadeOut()
        }

        panel.navigationController = nav

        let hudView = HUDView(nav: nav)
        panel.contentView = NSHostingView(rootView: hudView)

        self.hudPanel = panel
        self.navigationController = nav
    }

    // MARK: - Map Panel Setup

    private func setupMapPanel() {
        mapPanel = MapPanel()
    }

    // MARK: - Global Hotkey  (⌘ + §)
    //
    // We use Carbon RegisterEventHotKey — the same API Spotlight, Raycast,
    // Alfred, and Rectangle use. It registers a SINGLE system-level chord
    // and requires ZERO permissions (no Accessibility prompt).

    private func registerGlobalHotkey() {
        // 1. Carbon global hotkey — fires from any app, no permissions.
        let signature: OSType = 0x4E4D4348 // 'NMCH'

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(
                eventRef,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            // 0x4E4D4348 == 'NMCH'. Literal (not captured) so this stays
            // a valid C function pointer.
            if hkID.signature == OSType(0x4E4D4348) {
                DispatchQueue.main.async { AppDelegate.toggleHUD() }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &hotKeyHandlerRef
        )

        // Register ⌘ + each candidate § keycode (10 and 42).
        for (index, keyCode) in hotkeyKeyCodes.enumerated() {
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            RegisterEventHotKey(
                keyCode,
                UInt32(cmdKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if let ref = ref { hotKeyRefs.append(ref) }
        }

        // 2. Local NSEvent monitor — fires only when HUD/our window is key.
        //    Needed so ⌘§ also CLOSES the HUD while it's in front.
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if event.modifierFlags.contains(.command),
               self?.hotkeyKeyCodes.contains(UInt32(event.keyCode)) == true {
                self?.toggleHUD()
                return nil
            }
            return event
        }
    }

    deinit {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let h   = hotKeyHandlerRef  { RemoveEventHandler(h) }
        if let m   = localHotkeyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Toggle HUD (⌘§)

    func toggleHUD() {
        // Wizard is open → bring it to front, never the HUD.
        if wizardIsActive {
            wizardPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // First launch → only the wizard is allowed.
        if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            showWizard()
            return
        }

        guard let panel = hudPanel,
              let nav = navigationController
        else { return }

        if panel.isVisible {
            panel.fadeOut()
        } else {
            mapPanel?.fadeOut()          // never show HUD + Map at once
            nav.refresh()
            NSApp.activate(ignoringOtherApps: true)
            panel.fadeIn()
        }
    }

    static func toggleHUD() {
        AppDelegate.shared?.toggleHUD()
    }

    // MARK: - Toggle Map (from HUD, press M)

    /// Called from the HUD: hides HUD first, then opens the map.
    func switchToMap() {
        if wizardIsActive || !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            return
        }
        hudPanel?.fadeOut()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showMap()
        }
    }

    static func switchToMap() {
        AppDelegate.shared?.switchToMap()
    }

    func toggleMap() {
        if wizardIsActive || !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            return
        }
        guard let panel = mapPanel else { return }

        if panel.isVisible {
            panel.fadeOut()
        } else {
            showMap()
        }
    }

    /// Called when the user presses "Back" or Esc on the map — returns to HUD.
    func switchToHUD() {
        mapPanel?.fadeOut()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self,
                  let panel = self.hudPanel,
                  let nav = self.navigationController
            else { return }
            nav.refresh()
            NSApp.activate(ignoringOtherApps: true)
            panel.fadeIn()
        }
    }

    static func switchToHUD() {
        AppDelegate.shared?.switchToHUD()
    }

    private func showMap() {
        guard let panel = mapPanel else { return }

        hudPanel?.fadeOut()              // never show HUD + Map at once

        let context = PersistenceController.shared.container.viewContext
        let request = Project.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Project.sortOrder, ascending: true)
        ]
        let projects = (try? context.fetch(request)) ?? []

        let mapView = MapView(
            projects: projects,
            onJump: { [weak self] windowID in
                self?.jumpToWindow(windowID: windowID)
            },
            onDismiss: {
                AppDelegate.switchToHUD()
            }
        )
        panel.contentView = NSHostingView(rootView: mapView)

        NSApp.activate(ignoringOtherApps: true)
        panel.fadeIn()
    }

    static func toggleMap() {
        AppDelegate.shared?.toggleMap()
    }

    // MARK: - Jump to Window

    private func jumpToWindow(windowID: Int32) {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        guard let info = windowList.first(where: {
            if let num = $0[kCGWindowNumber as String] as? Int {
                return Int32(bitPattern: UInt32(truncatingIfNeeded: num)) == windowID
            }
            return false
        }),
        let pid = info[kCGWindowOwnerPID as String] as? pid_t
        else { return }

        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps])
            
        WindowHighlighter.shared.highlight(windowID: CGWindowID(bitPattern: windowID))
    }

    /// Legacy alias kept for MenuBarExtra compatibility.
    static func toggleMainPanel() {
        toggleHUD()
    }
}

// MARK: - Window Highlighter

final class WindowHighlighter {
    static let shared = WindowHighlighter()
    
    private var highlightWindow: NSPanel?
    private var fadeTimer: Timer?
    
    private init() {}
    
    func highlight(windowID: CGWindowID) {
        // Trova i bounds correnti della finestra reale
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
            return
        }
        
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { return }
        
        // Converti l'origine y da top-left (CoreGraphics) a bottom-left (Cocoa)
        if let mainScreen = NSScreen.screens.first {
            let screenHeight = mainScreen.frame.height
            bounds.origin.y = screenHeight - bounds.origin.y - bounds.size.height
        }
        
        // Esegui il disegno e l'animazione sul thread principale
        DispatchQueue.main.async { [weak self] in
            self?.showHighlight(frame: bounds)
        }
    }
    
    private func showHighlight(frame: NSRect) {
        fadeTimer?.invalidate()
        
        if highlightWindow == nil {
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver // Resta in assoluto primo piano, sopra l'HUD e altre app
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
            
            let highlightView = HighlightView()
            panel.contentView = highlightView
            self.highlightWindow = panel
        }
        
        guard let panel = highlightWindow else { return }
        
        // Applica le coordinate e mostra la finestra overlay
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.alphaValue = 1.0
        
        // Dissolvenza (fade-out) fluida dopo 1.0 secondi
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }
}

// Vista custom che disegna una cornice luminosa con effetto glow
private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let strokeWidth: CGFloat = 4.0
        // Applica un piccolo inset per disegnare la linea all'interno dei limiti fisici del pannello
        let rect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        
        context.saveGState()
        
        // Crea un tracciato arrotondato
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(path)
        
        // 1. Disegna l'ombra/glow esterno bianco brillante
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(strokeWidth)
        context.setShadow(offset: .zero, blur: 12.0, color: NSColor.white.cgColor)
        context.strokePath()
        
        // 2. Disegna una linea interna bianca e definita
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.0)
        context.strokePath()
        
        context.restoreGState()
    }
}
