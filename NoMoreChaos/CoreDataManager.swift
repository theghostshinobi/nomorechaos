import CoreData

final class CoreDataManager: ObservableObject {
    let viewContext: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.viewContext = context
    }

    // MARK: - Project

    @discardableResult
    func createProject(name: String, colorHex: String = "#0A84FF") -> Project {
        let project = Project(context: viewContext)
        project.id = UUID()
        project.name = name
        project.colorHex = colorHex
        project.sortOrder = Int16(fetchProjects().count)
        project.createdAt = Date()
        save()
        return project
    }

    func fetchProjects() -> [Project] {
        let request: NSFetchRequest<Project> = Project.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Project.sortOrder, ascending: true)
        ]
        return (try? viewContext.fetch(request)) ?? []
    }

    func deleteProject(_ project: Project) {
        viewContext.delete(project)
        save()
    }

    // MARK: - AppGroup

    func findOrCreateAppGroup(
        bundleID: String,
        appName: String,
        project: Project
    ) -> AppGroup {
        let request: NSFetchRequest<AppGroup> = AppGroup.fetchRequest()
        request.predicate = NSPredicate(
            format: "appBundleID == %@ AND appName == %@ AND project == %@",
            bundleID, appName, project
        )

        if let existing = try? viewContext.fetch(request).first {
            return existing
        }

        let group = AppGroup(context: viewContext)
        group.appBundleID = bundleID
        group.appName = appName
        group.sortOrder = 0
        group.project = project
        save()
        return group
    }

    // MARK: - WindowEntry

    @discardableResult
    func assignWindow(
        windowID: Int32,
        title: String,
        bundleID: String,
        appName: String,
        x: Double = 0,
        y: Double = 0,
        to project: Project
    ) -> WindowEntry {
        let appGroup = findOrCreateAppGroup(
            bundleID: bundleID,
            appName: appName,
            project: project
        )

        // Remove from any previous assignment
        let existingRequest: NSFetchRequest<WindowEntry> = WindowEntry.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "windowID == %d", windowID)
        if let existing = try? viewContext.fetch(existingRequest).first {
            viewContext.delete(existing)
        }

        let entry = WindowEntry(context: viewContext)
        entry.windowID = windowID
        entry.windowTitle = title
        entry.windowX = x
        entry.windowY = y
        entry.isActive = true
        entry.lastSeenAt = Date()
        entry.appGroup = appGroup
        save()
        return entry
    }

    /// One-shot cleanup of legacy junk assignments created BEFORE the
    /// layer-0 window filter existed (e.g. "Window Server" groups, whose
    /// bundle id was stored as "unknown"). Deleting the AppGroup cascades
    /// to its WindowEntries.
    func purgeLegacyJunk() {
        let request: NSFetchRequest<AppGroup> = AppGroup.fetchRequest()
        request.predicate = NSPredicate(
            format: "appBundleID == %@ OR appBundleID == %@ OR appBundleID == nil",
            "unknown", ""
        )
        if let groups = try? viewContext.fetch(request), !groups.isEmpty {
            groups.forEach { viewContext.delete($0) }
            save()
        }
    }

    func removeWindowAssignment(windowID: Int32) {
        let request: NSFetchRequest<WindowEntry> = WindowEntry.fetchRequest()
        request.predicate = NSPredicate(format: "windowID == %d", windowID)
        if let entry = try? viewContext.fetch(request).first {
            let appGroup = entry.appGroup
            viewContext.delete(entry)
            if let group = appGroup {
                let remaining = (group.windowEntries as? Set<WindowEntry>)?.filter { $0 != entry && !$0.isDeleted } ?? []
                if remaining.isEmpty {
                    viewContext.delete(group)
                }
            }
            save()
        }
    }

    func projectForWindow(windowID: Int32) -> Project? {
        let request: NSFetchRequest<WindowEntry> = WindowEntry.fetchRequest()
        request.predicate = NSPredicate(format: "windowID == %d", windowID)
        return (try? viewContext.fetch(request).first)?.appGroup?.project
    }

    // MARK: - Reconciliation
    //
    // A CGWindowID is NOT stable: it changes when a window closes/reopens
    // and after every login. Persisting it alone means saved assignments
    // rot. We instead re-identify a saved window by its (bundleID, title)
    // signature and, when the live window is found, refresh its windowID
    // and liveness. Windows no longer open are flagged inactive (kept, so
    // they re-attach automatically the next time they appear).

    private func signature(bundleID: String, appName: String, title: String, x: Double, y: Double) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            // No real title (e.g. Screen Recording permission not granted) —
            // disambiguate same-app windows by position as a best-effort
            // tiebreaker so two of them don't collapse to one identity.
            return bundleID + "\u{0}" + a + "\u{0}@\(Int(x.rounded())),\(Int(y.rounded()))"
        }
        return bundleID + "\u{0}" + a + "\u{0}" + t
    }

    func reconcile(openWindows: [TrackedWindow]) {
        let now = Date()

        // Group open windows by signature for Pass 2 (fallback signature matching)
        var liveBySignature: [String: [Int32]] = [:]
        for w in openWindows {
            let sig = signature(bundleID: w.bundleID, appName: w.appName, title: w.title, x: w.x, y: w.y)
            liveBySignature[sig, default: []].append(Int32(bitPattern: UInt32(truncatingIfNeeded: w.id)))
        }

        let request: NSFetchRequest<WindowEntry> = WindowEntry.fetchRequest()
        guard let entries = try? viewContext.fetch(request) else { return }

        // Pass 1: Match entries whose stored windowID is still live and belongs to the same app bundle.
        // If a window is still open on the system (even if its title or position changed),
        // we keep the match, and update the title and position in the database.
        let openWindowsByID = Dictionary(
            uniqueKeysWithValues: openWindows.map { (Int32(bitPattern: UInt32(truncatingIfNeeded: $0.id)), $0) }
        )

        var unmatched: [WindowEntry] = []
        for entry in entries {
            if let liveWin = openWindowsByID[entry.windowID] {
                if liveWin.bundleID == entry.appGroup?.appBundleID {
                    // Update dynamic properties
                    if entry.windowTitle != liveWin.title {
                        entry.windowTitle = liveWin.title
                        NavigationController.invalidateScreenshotCache(for: entry.windowID)
                    }
                    entry.windowX = liveWin.x
                    entry.windowY = liveWin.y
                    entry.isActive = true
                    entry.lastSeenAt = now
                    
                    // Consume this live window from the fallback pool
                    let s = signature(bundleID: liveWin.bundleID, appName: liveWin.appName, title: liveWin.title, x: liveWin.x, y: liveWin.y)
                    if var ids = liveBySignature[s], let idx = ids.firstIndex(of: entry.windowID) {
                        ids.remove(at: idx)
                        liveBySignature[s] = ids
                    }
                    continue
                }
            }
            unmatched.append(entry)
        }

        func sig(_ e: WindowEntry) -> String {
            signature(bundleID: e.appGroup?.appBundleID ?? "",
                      appName: e.appGroup?.appName ?? "",
                      title: e.windowTitle ?? "",
                      x: e.windowX, y: e.windowY)
        }

        // Pass 2: entries whose old windowID is gone re-attach to any
        // remaining live window with the same signature; the rest go idle.
        for entry in unmatched {
            let s = sig(entry)
            if var ids = liveBySignature[s], !ids.isEmpty {
                let liveID = ids.removeFirst()
                liveBySignature[s] = ids
                
                let oldID = entry.windowID
                if oldID != liveID {
                    NavigationController.invalidateScreenshotCache(for: oldID)
                    NavigationController.invalidateScreenshotCache(for: liveID)
                }
                
                entry.windowID = liveID
                entry.isActive = true
                entry.lastSeenAt = now
            } else if entry.isActive {
                entry.isActive = false
            }
        }

        save()
    }

    // MARK: - Save

    func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            print("Core Data save error: \(error)")
        }
    }
}
