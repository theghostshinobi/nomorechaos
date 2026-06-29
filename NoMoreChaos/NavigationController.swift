import Cocoa
import Combine
import CoreData
import ScreenCaptureKit

final class NavigationController: ObservableObject {

    // MARK: - Selection State

    @Published var selectedProjectIndex: Int = 0
    @Published var selectedAppGroupIndex: Int = 0
    @Published var selectedWindowIndex: Int = 0

    /// Index of the highlighted row inside the "available windows" list.
    /// Separate from the assigned-window selection because TAB lets the user
    /// move between the two columns and each side keeps its own cursor.
    @Published var selectedAvailableIndex: Int = 0

    /// When true the "new project" text field in the sidebar has keyboard
    /// focus. Synchronised with SwiftUI's @FocusState in HUDView.
    @Published var isProjectFieldFocused: Bool = false

    @Published var windowSearchText: String = "" {
        didSet {
            refreshAvailableWindows()
        }
    }

    /// Which column the keyboard is currently driving. TAB cycles through it.
    enum Focus { case projects, assigned, available }
    @Published var focus: Focus = .projects {
        didSet {
            if focus != .projects {
                isProjectFieldFocused = false
            }
        }
    }

    /// Whether we are currently in "Add Windows" mode (vertical list)
    /// vs "View Mode" (horizontal icons row + large preview).
    @Published var isAddingWindows: Bool = false

    // MARK: - Data

    @Published var projects: [Project] = []
    @Published var appGroups: [AppGroup] = []
    @Published var windowEntries: [WindowEntry] = []

    /// Currently open windows NOT yet assigned to the selected project.
    /// These are offered in the HUD so the user can add them.
    @Published var availableWindows: [TrackedWindow] = []

    /// Which project (if any) currently owns each open window — keyed by
    /// windowID. Drives the colored project tag shown next to every window in
    /// the "add windows" list, so the same app's windows are visibly split
    /// across different projects.
    @Published var windowOwners: [Int32: WindowOwner] = [:]

    struct WindowOwner {
        let projectName: String
        let colorHex: String
        let isCurrent: Bool   // true when the owner IS the selected project
    }

    /// Called when the HUD should dismiss (e.g. after a jump).
    var onDismiss: (() -> Void)?

    /// Cache of window screenshots keyed by CGWindowID.
    /// Survives HUD open/close cycles so thumbnails appear instantly.
    static let screenshotCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 50
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        return cache
    }()

    private let viewContext: NSManagedObjectContext
    private let windowTracker = WindowTracker.shared
    private lazy var coreData = CoreDataManager(context: viewContext)
    private var cancellables = Set<AnyCancellable>()

    init(context: NSManagedObjectContext) {
        self.viewContext = context

        // The tracker scans in background and republishes when ready. Listen
        // so the HUD repaints the available-windows list as soon as a fresh
        // scan lands, even if it opened with a stale snapshot.
        windowTracker.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableWindows()
            }
            .store(in: &cancellables)
    }

    // MARK: - Create project (inline from HUD onboarding)

    @discardableResult
    func createProject(name: String, colorHex: String = "#0A84FF") -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let project = Project(context: viewContext)
        project.id = UUID()
        project.name = trimmed
        project.colorHex = colorHex
        project.sortOrder = Int16(projects.count)
        project.createdAt = Date()
        do {
            try viewContext.save()
        } catch {
            print("Create project save error: \(error)")
            return nil
        }
        refresh()
        selectedProjectIndex = projects.count - 1
        refreshAppGroups()
        return project
    }

    func renameProject(at index: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard projects.indices.contains(index), !trimmed.isEmpty else { return }
        projects[index].name = trimmed
        do {
            try viewContext.save()
        } catch {
            print("[NavigationController] Failed to save viewContext after project rename at index \(index): \(error)")
        }
        objectWillChange.send()
    }

    func deleteProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        let project = projects[index]
        coreData.deleteProject(project)
        viewContext.refreshAllObjects()
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        let request: NSFetchRequest<Project> = Project.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Project.sortOrder, ascending: true)
        ]
        projects = (try? viewContext.fetch(request)) ?? []
        selectedProjectIndex = min(selectedProjectIndex, max(projects.count - 1, 0))
        refreshAppGroups()
        focus = defaultFocus()
        preWarmScreenshotCache()
    }

    /// Pick a sensible starting focus when the HUD opens: the column the user
    /// is most likely to act on first.
    private func defaultFocus() -> Focus {
        if !windowEntries.isEmpty { return .assigned }
        if !availableWindows.isEmpty { return .available }
        return .projects
    }

    // MARK: - Available (open, unassigned) windows

    /// Open windows that are NOT already assigned to the selected project.
    /// Shown in the HUD so the user can add them to the current project.
    func refreshAvailableWindows() {
        let open = windowTracker.currentWindows()

        let assignedToCurrent: Set<Int32> = Set(
            appGroups
                .flatMap { ($0.windowEntries as? Set<WindowEntry>) ?? [] }
                .map { $0.windowID }
        )
        let searchText = windowSearchText

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var filtered = open.filter { !assignedToCurrent.contains(Int32(bitPattern: UInt32(truncatingIfNeeded: $0.id))) }
            if !searchText.isEmpty {
                filtered = filtered.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(searchText) ||
                    $0.appName.localizedCaseInsensitiveContains(searchText)
                }
            }
            let grouped = Dictionary(grouping: filtered, by: { $0.bundleID })
            let sortedGroups = grouped.map { (bundleID, wins) in
                (bundleID,
                 wins.first?.appName ?? bundleID,
                 wins.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending })
            }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            
            let result = sortedGroups.flatMap { $0.2 }
            
            DispatchQueue.main.async {
                self.availableWindows = result
                self.rebuildWindowOwners()
                if self.availableWindows.isEmpty {
                    self.selectedAvailableIndex = 0
                } else {
                    self.selectedAvailableIndex = max(0, min(self.selectedAvailableIndex, self.availableWindows.count - 1))
                }
            }
        }
    }

    /// Build the windowID → owning-project map across ALL projects so the HUD
    /// can tag each open window with the color of the project it belongs to.
    func rebuildWindowOwners() {
        let current = projects.indices.contains(selectedProjectIndex)
            ? projects[selectedProjectIndex] : nil

        var map: [Int32: WindowOwner] = [:]
        for project in projects {
            let groups = (project.appGroups as? Set<AppGroup>) ?? []
            for group in groups {
                for entry in ((group.windowEntries as? Set<WindowEntry>) ?? []) {
                    map[entry.windowID] = WindowOwner(
                        projectName: project.name ?? "",
                        colorHex: project.colorHex ?? "#0A84FF",
                        isCurrent: project === current
                    )
                }
            }
        }
        windowOwners = map
    }

    /// Assign an open window to the currently selected project.
    func assign(_ window: TrackedWindow) {
        guard projects.indices.contains(selectedProjectIndex) else { return }
        let project = projects[selectedProjectIndex]
        coreData.assignWindow(
            windowID: Int32(bitPattern: UInt32(truncatingIfNeeded: window.id)),
            title: window.title,
            bundleID: window.bundleID,
            appName: window.appName,
            x: window.x,
            y: window.y,
            to: project
        )
        // Reload Core Data objects and recompute everything.
        viewContext.refreshAllObjects()
        refreshAppGroups()
        
        // Auto-exit adding mode once window is assigned, and focus on the newly added window
        isAddingWindows = false
        focus = .assigned
        selectedWindowIndex = windowEntries.count - 1
    }

    func assignAll(_ windows: [TrackedWindow]) {
        guard projects.indices.contains(selectedProjectIndex) else { return }
        let project = projects[selectedProjectIndex]
        for window in windows {
            coreData.assignWindow(
                windowID: Int32(bitPattern: UInt32(truncatingIfNeeded: window.id)),
                title: window.title,
                bundleID: window.bundleID,
                appName: window.appName,
                x: window.x,
                y: window.y,
                to: project
            )
        }
        viewContext.refreshAllObjects()
        refreshAppGroups()
        
        isAddingWindows = false
        focus = .assigned
        selectedWindowIndex = windowEntries.count - 1
    }

    /// Remove a window assignment from the current project.
    func unassign(windowID: Int32) {
        coreData.removeWindowAssignment(windowID: windowID)
        viewContext.refreshAllObjects()
        refreshAppGroups()
        refreshAvailableWindows()
        if windowEntries.isEmpty {
            isAddingWindows = true
            focus = .available
            selectedAvailableIndex = 0
        } else {
            selectedWindowIndex = min(selectedWindowIndex, windowEntries.count - 1)
        }
    }

    func refreshAppGroups() {
        guard projects.indices.contains(selectedProjectIndex) else {
            appGroups = []
            windowEntries = []
            isAddingWindows = false
            return
        }

        let project = projects[selectedProjectIndex]
        appGroups = (project.appGroups as? Set<AppGroup>)?
            .sorted { ($0.appName ?? "") < ($1.appName ?? "") } ?? []

        selectedAppGroupIndex = min(selectedAppGroupIndex, max(appGroups.count - 1, 0))
        refreshWindowEntries()
        refreshAvailableWindows()
        
        // Auto-toggle adding windows mode if project has no windows
        isAddingWindows = windowEntries.isEmpty
    }

    func refreshWindowEntries() {
        var allEntries: [WindowEntry] = []
        for group in appGroups {
            let entries = (group.windowEntries as? Set<WindowEntry>)?
                .filter { $0.isActive }
                .sorted { ($0.windowTitle ?? "") < ($1.windowTitle ?? "") } ?? []
            allEntries.append(contentsOf: entries)
        }
        windowEntries = allEntries.sorted { a, b in
            let appA = a.appGroup?.appName ?? ""
            let appB = b.appGroup?.appName ?? ""
            if appA != appB {
                return appA.localizedCaseInsensitiveCompare(appB) == .orderedAscending
            }
            let titleA = a.windowTitle ?? ""
            let titleB = b.windowTitle ?? ""
            return titleA.localizedCaseInsensitiveCompare(titleB) == .orderedAscending
        }
        selectedWindowIndex = min(selectedWindowIndex, max(windowEntries.count - 1, 0))
    }

    // MARK: - Project Navigation (↑ / ↓)

    func moveProjectUp() {
        guard selectedProjectIndex > 0 else { return }
        selectedProjectIndex -= 1
        selectedAppGroupIndex = 0
        selectedWindowIndex = 0
        refreshAppGroups()
    }

    func moveProjectDown() {
        guard selectedProjectIndex < projects.count - 1 else { return }
        selectedProjectIndex += 1
        selectedAppGroupIndex = 0
        selectedWindowIndex = 0
        refreshAppGroups()
    }

    // MARK: - Window Navigation (← / →)

    func moveWindowLeft() {
        if selectedWindowIndex > 0 {
            selectedWindowIndex -= 1
        }
    }

    func moveWindowRight() {
        if selectedWindowIndex < windowEntries.count - 1 {
            selectedWindowIndex += 1
        }
    }

    // MARK: - Jump to Window (↩)

    func jumpToSelectedWindow() {
        guard windowEntries.indices.contains(selectedWindowIndex) else { return }
        let entry = windowEntries[selectedWindowIndex]
        let targetWindowID = entry.windowID
        
        let liveBundleID: String? = {
            let cgWindowID = CGWindowID(bitPattern: targetWindowID)
            guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, cgWindowID) as? [[String: Any]],
                  let info = list.first,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { return entry.appGroup?.appBundleID }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? entry.appGroup?.appBundleID
        }()

        Task {
            let raised = await AXWindows.raise(
                windowID: CGWindowID(bitPattern: targetWindowID),
                bundleID: liveBundleID
            )

            await MainActor.run { [weak self] in
                if !raised {
                    if let windowList = CGWindowListCopyWindowInfo(
                        [.optionAll], kCGNullWindowID
                    ) as? [[String: Any]],
                       let info = windowList.first(where: {
                           ($0[kCGWindowNumber as String] as? CGWindowID) == CGWindowID(bitPattern: targetWindowID)
                       }),
                       let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                        NSRunningApplication(processIdentifier: pid)?
                            .activate(options: [.activateIgnoringOtherApps])
                    }
                }
                WindowHighlighter.shared.highlight(windowID: CGWindowID(bitPattern: targetWindowID))
                self?.onDismiss?()
            }
        }
    }

    // MARK: - Window Screenshot Capture

    // macOS 14+ uses ScreenCaptureKit — CGWindowListCreateImage returns nil
    // at runtime on macOS 15+, which is why thumbnails were blank. macOS 13
    // falls back to the legacy API.

    static func cacheKey(for windowID: Int32) -> NSNumber {
        return NSNumber(value: Int(UInt32(bitPattern: windowID)))
    }

    static func cacheKey(for cgWindowID: CGWindowID) -> NSNumber {
        return NSNumber(value: Int(cgWindowID))
    }

    static func captureWindowImageAsync(windowID: Int32, ignoreCache: Bool = false) async -> NSImage? {
        let key = cacheKey(for: windowID)
        if !ignoreCache, let cached = screenshotCache.object(forKey: key) {
            return cached
        }

        guard CGPreflightScreenCaptureAccess() else { return nil }

        // Utilizziamo l'API legacy sincrona (CGWindowListCreateImage) che è fulminea
        // e immediata (<10ms).
        if let image = captureWindowImageLegacy(windowID: windowID) {
            cacheImage(image, forKey: key)
            return image
        }

        // Se fallisce (es. finestra su un altro Space o macOS 15+), ripieghiamo su ScreenCaptureKit
        if #available(macOS 14.0, *) {
            if let image = await captureWithScreenCaptureKit(windowID: windowID) {
                cacheImage(image, forKey: key)
                return image
            }
        }

        return nil
    }

    private static func cacheImage(_ image: NSImage, forKey key: NSNumber) {
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let width = cgImage?.width ?? Int(image.size.width)
        let height = cgImage?.height ?? Int(image.size.height)
        let cost = width * height * 4
        screenshotCache.setObject(image, forKey: key, cost: cost > 0 ? cost : 1024 * 1024)
    }

    static func invalidateScreenshotCache(for windowID: CGWindowID) {
        screenshotCache.removeObject(forKey: cacheKey(for: windowID))
    }

    static func invalidateScreenshotCache(for windowID: Int32) {
        screenshotCache.removeObject(forKey: cacheKey(for: windowID))
    }

    func preWarmScreenshotCache() {
        let ids = windowEntries.map { $0.windowID }
        Task.detached(priority: .utility) {
            for id in ids {
                let key = NavigationController.cacheKey(for: id)
                if NavigationController.screenshotCache.object(forKey: key) == nil {
                    _ = await NavigationController.captureWindowImageAsync(windowID: id)
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit(windowID: Int32) async -> NSImage? {
        do {
            var content = try await ShareableContentCache.shared.content()
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(bitPattern: windowID) }) else { return nil }

            // Se la finestra è su un altro Space o minimizzata, non è sullo schermo (isOnScreen è false).
            // Lo screenshot con ScreenCaptureKit fallirebbe comunque, sprecando CPU e potenzialmente
            // causando memory leak nei percorsi interni di errore della GPU.
            guard scWindow.isOnScreen else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = filter.pointPixelScale
            let pointSize = filter.contentRect.size
            config.width  = max(Int((pointSize.width  * CGFloat(scale)).rounded()), 1)
            config.height = max(Int((pointSize.height * CGFloat(scale)).rounded()), 1)
            config.scalesToFit = true
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Forza la copia dei pixel in una bitmap CPU per rilasciare immediatamente l'IOSurface della GPU.
            let width = cgImage.width
            let height = cgImage.height
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let cpuCgImage = context.makeImage() else {
                return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            }

            return NSImage(
                cgImage: cpuCgImage,
                size: NSSize(width: width, height: height)
            )
        } catch {
            print("[NavigationController] ScreenCaptureKit capture failed for window \(windowID): \(error)")
            return nil
        }
    }

    static func captureWindowImageLegacy(windowID: Int32) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(bitPattern: windowID),
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    // MARK: - Keyboard Handler

    /// Returns `true` if the event was consumed.
    ///
    /// Key map:
    /// - TAB             cycle focus between the 3 columns
    /// - ↑ / ↓           move selection DOWN/UP the focused column
    /// - ← / →           move project (focus=projects) or assigned window (focus=assigned)
    /// - ⏎               focus=available → assign; focus=assigned → jump
    /// - ⌫               focus=assigned   → unassign currently selected window
    /// - ⌘1…⌘9           jump straight to that project (regardless of focus)
    func handleKeyDown(_ event: NSEvent) -> Bool {

        // If editing a text field, let it handle typing characters, left/right arrows, and Return.
        // But intercept Escape, Tab, Up, and Down for navigation.
        if isProjectFieldFocused {
            let navKeys: Set<UInt16> = [48, 53, 125, 126] // Tab, Escape, Down, Up
            if !navKeys.contains(event.keyCode) {
                return false
            }
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘1...⌘9 → quick project switch (works from any focus).
        if mods == .command,
           let ch = event.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n),
           projects.indices.contains(n - 1) {
            selectedProjectIndex = n - 1
            selectedAppGroupIndex = 0
            selectedWindowIndex = 0
            refreshAppGroups()
            return true
        }

        switch event.keyCode {
        case 46:   // 'M' or 'm' key
            if !projects.isEmpty {
                AppDelegate.switchToMap()
                return true
            }
            return false

        case 48:   // TAB
            isProjectFieldFocused = false
            focus = nextFocus()
            return true

        case 126:  // ↑
            handleUpDown(delta: -1)
            return true

        case 125:  // ↓
            handleUpDown(delta: +1)
            return true

        case 123:  // ←
            handleLeftRight(delta: -1)
            return true

        case 124:  // →
            handleLeftRight(delta: +1)
            return true

        case 36:   // ↩ Return
            switch focus {
            case .available:
                if availableWindows.indices.contains(selectedAvailableIndex) {
                    assign(availableWindows[selectedAvailableIndex])
                }
            case .assigned:
                if selectedWindowIndex == windowEntries.count {
                    // Clicked "+" card
                    isAddingWindows = true
                    focus = .available
                    selectedAvailableIndex = 0
                } else {
                    jumpToSelectedWindow()
                }
            case .projects:
                jumpToSelectedWindow()
            }
            return true

        case 51:   // ⌫ Backspace
            if focus == .assigned {
                if windowEntries.indices.contains(selectedWindowIndex) {
                    let id = windowEntries[selectedWindowIndex].windowID
                    unassign(windowID: id)
                }
                return true
            }
            return false

        case 53:   // Escape
            if isProjectFieldFocused {
                isProjectFieldFocused = false
                return true
            }
            if isAddingWindows && !windowEntries.isEmpty {
                isAddingWindows = false
                focus = .assigned
                selectedWindowIndex = min(selectedWindowIndex, windowEntries.count - 1)
                return true
            }
            return false

        default:
            return false
        }
    }

    // Cycle order skips columns that have nothing in them, so TAB never lands
    // on an empty section.
    private func nextFocus() -> Focus {
        let order: [Focus] = [.projects, .assigned, .available]
        let start = order.firstIndex(of: focus) ?? 0
        for offset in 1...order.count {
            let candidate = order[(start + offset) % order.count]
            if isFocusable(candidate) { return candidate }
        }
        return focus
    }

    private func isFocusable(_ f: Focus) -> Bool {
        switch f {
        case .projects:  return !projects.isEmpty
        case .assigned:  return !windowEntries.isEmpty && !isAddingWindows
        case .available: return !availableWindows.isEmpty && isAddingWindows
        }
    }

    private func handleUpDown(delta: Int) {
        switch focus {
        case .projects:
            if isProjectFieldFocused {
                if delta < 0, !projects.isEmpty {
                    isProjectFieldFocused = false
                    selectedProjectIndex = projects.count - 1
                    refreshAppGroups()
                }
                return
            }
            let next = max(0, min(projects.count - 1, selectedProjectIndex + delta))
            if next != selectedProjectIndex {
                selectedProjectIndex = next
                selectedAppGroupIndex = 0
                selectedWindowIndex = 0
                refreshAppGroups()
            } else if delta > 0, next == projects.count - 1 {
                isProjectFieldFocused = true
            }
        case .assigned:
            // UP/DOWN moves to projects
            focus = .projects
        case .available:
            // Available windows list is a vertical list, so UP/DOWN navigates it
            let next = selectedAvailableIndex + delta
            if next < 0 {
                if isFocusable(.assigned) {
                    isAddingWindows = false
                    focus = .assigned
                    selectedWindowIndex = min(selectedWindowIndex, windowEntries.count - 1)
                } else {
                    focus = .projects
                }
            } else {
                selectedAvailableIndex = max(0, min(availableWindows.count - 1, next))
            }
        }
    }

    private func handleLeftRight(delta: Int) {
        switch focus {
        case .projects:
            if delta > 0 {
                isProjectFieldFocused = false
                if isFocusable(.assigned) {
                    focus = .assigned
                    selectedWindowIndex = 0
                } else if isFocusable(.available) {
                    focus = .available
                    selectedAvailableIndex = 0
                }
            }
        case .assigned:
            if delta < 0 {
                if selectedWindowIndex > 0 {
                    selectedWindowIndex -= 1
                } else {
                    focus = .projects
                }
            } else {
                if selectedWindowIndex < windowEntries.count {
                    selectedWindowIndex += 1
                }
            }
        case .available:
            if delta < 0 {
                if !windowEntries.isEmpty {
                    isAddingWindows = false
                    focus = .assigned
                    selectedWindowIndex = min(selectedWindowIndex, windowEntries.count - 1)
                } else {
                    focus = .projects
                }
            }
        }
    }

}

// MARK: - Shareable Content Cache
//
// SCShareableContent enumerates EVERY window on the system. When the HUD/Map
// capture N thumbnails at once, paying that enumeration N times is janky, so
// this actor memoises it for a short TTL and coalesces concurrent callers onto
// one in-flight fetch. The TTL is short so new/closed windows show up quickly.
@available(macOS 14.0, *)
actor ShareableContentCache {
    static let shared = ShareableContentCache()

    private var cached: SCShareableContent?
    private var fetchedAt: Date = .distantPast
    private var inFlight: Task<SCShareableContent, Error>?
    private let ttl: TimeInterval = 0.5

    func content() async throws -> SCShareableContent {
        let now = Date()
        if let cached, now.timeIntervalSince(fetchedAt) < ttl {
            return cached
        }
        
        if let inFlight = inFlight {
            return try await inFlight.value
        }
        
        let task = Task<SCShareableContent, Error> {
            try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        }
        self.inFlight = task
        
        do {
            let result = try await task.value
            self.cached = result
            self.fetchedAt = Date()
            self.inFlight = nil
            return result
        } catch {
            self.inFlight = nil
            throw error
        }
    }

    func invalidate() {
        cached = nil
        fetchedAt = .distantPast
        inFlight?.cancel()
        inFlight = nil
    }
}
