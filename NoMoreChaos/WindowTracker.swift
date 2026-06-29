import Cocoa
import Combine
import ApplicationServices

struct TrackedWindow: Identifiable, Hashable {
    let id: Int          // CGWindowID
    let title: String    // RAW window title (empty when unavailable)
    let bundleID: String
    let appName: String
    let x: Double         // window position — tiebreaker when title is empty
    let y: Double

    /// Title for display: the real title, or the app name when empty.
    var displayTitle: String { title.isEmpty ? appName : title }
}

final class WindowTracker: ObservableObject {

    /// Single shared tracker. Previously two instances existed (one here,
    /// one injected into ContentView), each running its own 3 s timer and
    /// "new window" detection. They now share one.
    static let shared = WindowTracker()

    @Published private(set) var windows: [TrackedWindow] = []

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var knownWindowIDs: Set<Int> = []

    /// Used to re-match persisted window assignments against the live
    /// windows every cycle, so saved projects survive window/app restarts.
    private lazy var coreData = CoreDataManager(
        context: PersistenceController.shared.container.viewContext
    )

    private init() {
        if UserDefaults.standard.bool(forKey: "onboardingComplete") {
            // Returning user — permissions exist, start scanning immediately.
            refreshWindows()
            startTimer()
            observeAppActivation()
        }
        // First launch: do nothing. The wizard's onFinish calls
        // refreshWindows() which will bootstrap the timer.
    }

    /// Ensures the poll timer + workspace observer are running. Called
    /// after the wizard grants permissions so scanning can begin.
    func bootstrap() {
        guard timer == nil else { return }   // already running
        refreshWindows()
        startTimer()
        observeAppActivation()
    }

    // MARK: - Snapshot → real application windows

    /// THE window source. Uses CGWindowList with `.optionAll` — the ONLY
    /// enumeration that returns windows ACROSS ALL Spaces (not just the front
    /// one), so the same app's windows can be split between projects.
    ///
    /// (The Accessibility API's kAXWindows was tried first but only ever
    /// returns windows on the CURRENT Space — useless for a multi-desktop
    /// workflow. Accessibility is still used, separately, to RAISE a specific
    /// window on jump.)
    ///
    /// CRITICAL: macOS spontaneously triggers the Screen Recording permission
    /// prompt as soon as ANY caller asks for `kCGWindowName` of another app's
    /// window — that is what the user sees as a "the app keeps asking for
    /// permission" loop. So we gate the call: if Screen Recording is not
    /// granted, return an empty snapshot. The HUD has its own affordance to
    /// invite the user to grant it; we never fire the system prompt by side
    /// effect of a 3-second poll.
    private func snapshot() -> [TrackedWindow] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] else { return windows }
        return realWindows(from: infoList)
    }

    /// Keeps ONLY genuine document/app windows out of the full CGWindowList
    /// dump. `.optionAll` is noisy — it also returns per-Space menu-bar strips
    /// (1920×30), 1×1 helpers, transparent overlays and tiny popovers. We keep
    /// a window only when it looks like something the user would pick from the
    /// Dock's window menu: layer 0, visible, reasonably sized, and either it
    /// has a title (works on every Space) or it's a large window on screen.
    private func realWindows(from infoList: [[String: Any]]) -> [TrackedWindow] {
        let mine = Bundle.main.bundleIdentifier
        var out: [TrackedWindow] = []
        var seen = Set<Int>()

        for info in infoList {
            guard
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let ownerName    = info[kCGWindowOwnerName as String] as? String,
                let pid          = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer        = info[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }

            // Drop fully/near transparent overlay windows.
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.1 else { continue }

            // Real owning app (.accessory allowed so menu-bar apps with a real
            // window still count); never our own windows.
            let app = NSRunningApplication(processIdentifier: pid)
            if let app = app, app.activationPolicy == .prohibited {
                continue
            }

            let sanitizedOwner = ownerName.replacingOccurrences(of: " ", with: "-").lowercased()
            let bundleID = app?.bundleIdentifier ?? "local.utility.\(sanitizedOwner)"

            guard bundleID != mine else { continue }

            var bounds = CGRect.zero
            if let b = info[kCGWindowBounds as String] {
                CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &bounds)
            }
            // Kills the 1920×30 menu strips, 1×1 helpers and tiny popovers.
            guard bounds.width >= 120, bounds.height >= 120 else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false

            // A genuine window has a title (matches the Dock menu on ANY Space)
            // OR is a large window (covers untitled fronts/space windows).
            guard !title.isEmpty
                  || (bounds.width >= 400 && bounds.height >= 300)
            else { continue }

            guard !seen.contains(windowNumber) else { continue }
            seen.insert(windowNumber)

            out.append(TrackedWindow(
                id: windowNumber,
                title: title,
                bundleID: bundleID,
                appName: ownerName,
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y)
            ))
        }
        return out
    }

    // MARK: - Refresh

    func refreshWindows() {
        // Accessibility enumeration is IPC-heavy (many apps × many windows),
        // so build the snapshot off the main thread, then hop back to main for
        // all Core Data + @Published mutation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let tracked = self.snapshot()
            let currentIDs = Set(tracked.map { $0.id })

            DispatchQueue.main.async {
                let newIDs = currentIDs.subtracting(self.knownWindowIDs)
                self.knownWindowIDs = currentIDs

                // Re-attach persisted assignments to the live windows: refresh
                // the (volatile) windowID and liveness for windows still open,
                // mark the rest inactive — this makes saved projects survive
                // window/app restarts.
                self.coreData.reconcile(openWindows: tracked)



                self.windows = tracked
            }
        }
    }

    /// Last-published list of open windows — safe to read from the main
    /// thread. Used as the IMMEDIATE source when the HUD opens, so it never
    /// blocks waiting for a fresh CGWindowList scan (which can take measurable
    /// time on machines with many Spaces). A fresh scan is then kicked off
    /// asynchronously and will update `windows` shortly.
    @discardableResult
    func currentWindows() -> [TrackedWindow] {
        refreshWindows()      // off-main, updates @Published when ready
        return windows
    }

    // MARK: - Timer

    private func startTimer() {
        // Explicitly schedule on the main run loop in .common mode so the
        // poll keeps firing during menu/scroll tracking AND so the Core Data
        // work in refreshWindows always runs on the main thread.
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshWindows()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Workspace Observation

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshWindows()
            }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }
}
