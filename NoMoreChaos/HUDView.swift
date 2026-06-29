import SwiftUI
import AppKit

// MARK: - Visual Effect Background (Frosted Glass)

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}



// MARK: - Capture state machine
//
// Both the small thumbnail and the large preview share the same lifecycle: a
// capture is attempted; it either succeeds (image), fails (Apple returns nil
// for windows it can't currently render — common for minimised windows or
// other Spaces) or times out (3 s ceiling so we never sit on a spinner). The
// failed/timeout branch always renders the app icon + title fallback instead
// of an empty spinner, so the HUD always tells the user SOMETHING.
private enum CaptureState {
    case loading
    case loaded(NSImage)
    case failed
    
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Window Thumbnail (small, 80×55)

struct WindowThumbnailView: View {
    let windowID: Int32
    let bundleID: String?

    @State private var state: CaptureState = .loading

    var body: some View {
        ZStack {
            switch state {
            case .loaded(let img):
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .loading:
                Rectangle()
                    .fill(.white.opacity(0.05))
                    .overlay {
                        ProgressView().controlSize(.mini)
                    }
            case .failed:
                Rectangle()
                    .fill(.white.opacity(0.05))
                    .overlay {
                        if let bid = bundleID {
                            AppIconView(bundleID: bid)
                                .frame(width: 28, height: 28)
                                .opacity(0.55)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.2))
                        }
                    }
            }
        }
        .onAppear { capture() }
        .onChange(of: windowID) { _ in
            state = .loading
            capture()
        }
    }

    private func capture() {
        let id = windowID
        let key = NSNumber(value: id)

        if let cached = NavigationController.screenshotCache.object(forKey: key) {
            state = .loaded(cached)
            Task {
                if let fresh = await NavigationController.captureWindowImageAsync(windowID: id, ignoreCache: true),
                   id == windowID {
                    state = .loaded(fresh)
                }
            }
            return
        }

        state = .loading

        let captureTask = Task {
            await NavigationController.captureWindowImageAsync(windowID: id, ignoreCache: true)
        }
        
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if id == windowID && state.isLoading {
                state = .failed
                captureTask.cancel()
            }
        }
        
        Task {
            let img = await captureTask.value
            if id == windowID {
                state = img.map { .loaded($0) } ?? .failed
            }
        }
    }
}

// MARK: - Window Preview (large, 360×240)

struct WindowPreviewView: View {
    let windowID: Int32
    let bundleID: String?
    let title: String
    let size: CGSize

    @State private var state: CaptureState = .loading
    @State private var capturedID: Int32 = -1

    var body: some View {
        ZStack {
            switch state {
            case .loaded(let img):
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .loading:
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.05))
                    .overlay { ProgressView().controlSize(.small) }
            case .failed:
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.05))
                    .overlay {
                        VStack(spacing: 10) {
                            if let bid = bundleID {
                                AppIconView(bundleID: bid)
                                    .frame(width: 72, height: 72)
                                    .opacity(0.7)
                            } else {
                                Image(systemName: "macwindow")
                                    .font(.system(size: 38))
                                    .foregroundColor(.white.opacity(0.25))
                            }
                            Text(title)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { capture() }
        .onChange(of: windowID) { _ in capture() }
    }

    private func capture() {
        guard windowID != capturedID else { return }
        capturedID = windowID
        let id = windowID
        let key = NSNumber(value: id)

        if let cached = NavigationController.screenshotCache.object(forKey: key) {
            state = .loaded(cached)
            Task {
                if let fresh = await NavigationController.captureWindowImageAsync(windowID: id, ignoreCache: true),
                   id == capturedID {
                    state = .loaded(fresh)
                }
            }
            return
        }

        state = .loading

        let captureTask = Task {
            await NavigationController.captureWindowImageAsync(windowID: id, ignoreCache: true)
        }
        
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if id == capturedID && state.isLoading {
                state = .failed
                captureTask.cancel()
            }
        }
        
        Task {
            let img = await captureTask.value
            if id == capturedID {
                state = img.map { .loaded($0) } ?? .failed
            }
        }
    }
}

// MARK: - App Icon (from bundle ID)

struct AppIconView: NSViewRepresentable {
    let bundleID: String

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 150
        return c
    }()

    private static func cachedImage(for bundleID: String) -> NSImage? {
        cache.object(forKey: bundleID as NSString)
    }

    private static func setCachedImage(_ image: NSImage, for bundleID: String) {
        cache.setObject(image, forKey: bundleID as NSString)
    }

    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        loadIcon(into: iv)
        return iv
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        loadIcon(into: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private func loadIcon(into iv: NSImageView) {
        let bid = bundleID
        iv.identifier = NSUserInterfaceItemIdentifier(bid) // Tag the view to handle recycling safely
        if let cached = Self.cachedImage(for: bid) {
            iv.image = cached
            return
        }

        iv.image = NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: nil
        )

        DispatchQueue.global().async {
            let image: NSImage
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                image = NSImage(
                    systemSymbolName: "app.fill",
                    accessibilityDescription: nil
                ) ?? NSImage()
            }

            Self.setCachedImage(image, for: bid)

            DispatchQueue.main.async {
                // Ensure the view is still dedicated to this bundle ID before assigning
                if iv.identifier?.rawValue == bid {
                    iv.image = image
                }
            }
        }
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  MARK: - HUDView                                                ║
// ╚══════════════════════════════════════════════════════════════════╝

struct HUDView: View {
    @ObservedObject var nav: NavigationController
    @ObservedObject private var loc = Localizer.shared
    @State private var newProjectName: String = ""
    @State private var editingProjectIndex: Int? = nil
    @State private var editingProjectName: String = ""
    @FocusState private var projectFieldFocused: Bool
    @FocusState private var renameFieldFocused: Bool
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack {
            // Translucent glass backdrop
            Color.black.opacity(0.15)
            VisualEffectBackground()

            // Liquid-glass iridescent gradient
            LinearGradient(
                colors: [
                    Color(hue: 0.60, saturation: 0.45, brightness: 0.25).opacity(0.40),
                    Color(hue: 0.72, saturation: 0.40, brightness: 0.22).opacity(0.35),
                    Color(hue: 0.85, saturation: 0.35, brightness: 0.20).opacity(0.30),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle top-center highlight
            RadialGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 300
            )

            if nav.projects.isEmpty {
                onboardingView
            } else {
                mainLayout
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .frame(width: 860, height: 480)
        // Sync NavigationController → SwiftUI @FocusState
        .onChange(of: nav.isProjectFieldFocused) { newValue in
            if newValue {
                if !renameFieldFocused && !searchFieldFocused {
                    projectFieldFocused = true
                }
            } else {
                projectFieldFocused = false
                searchFieldFocused = false
            }
        }
        // Sync SwiftUI @FocusState → NavigationController
        .onChange(of: projectFieldFocused) { newValue in
            if nav.isProjectFieldFocused != newValue {
                nav.isProjectFieldFocused = newValue
            }
        }
        .onChange(of: searchFieldFocused) { newValue in
            if nav.isProjectFieldFocused != newValue {
                nav.isProjectFieldFocused = newValue
            }
        }
        // When the rename text field gains/loses focus, sync to the same
        // flag so handleKeyDown passes all keys through.
        .onChange(of: renameFieldFocused) { newValue in
            if newValue {
                nav.isProjectFieldFocused = true
            } else if !projectFieldFocused && !searchFieldFocused {
                nav.isProjectFieldFocused = false
            }
            // If the user clicks away (blur), commit the rename.
            if !newValue, let idx = editingProjectIndex {
                nav.renameProject(at: idx, to: editingProjectName)
                editingProjectIndex = nil
            }
        }
        .onChange(of: nav.isAddingWindows) { newValue in
            if !newValue {
                nav.windowSearchText = ""
            }
        }
    }

    // MARK: - Onboarding (no projects yet)

    private var onboardingView: some View {
        VStack(spacing: 22) {
            Spacer()

            Image("AppFalcon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 6) {
                Text(loc.tr("onboarding.welcome"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)

                Text(loc.tr("onboarding.subtitle"))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 8) {
                TextField(loc.tr("onboarding.placeholder"), text: $newProjectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(width: 320)
                    .focused($projectFieldFocused)
                    .onSubmit(createProjectFromOnboarding)

                Button(action: createProjectFromOnboarding) {
                    Text(loc.tr("common.create"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(
                            Color.accentColor
                                .opacity(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("⌘ §")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                Text(loc.tr("onboarding.hint"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.bottom, 20)
        }
    }

    private func createProjectFromOnboarding() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = nav.createProject(name: trimmed)
        newProjectName = ""
        // Keep focus on the text field so the user can create another
        // project right away (type → Enter → type → Enter…).
        // Toggle false→true: the onChange(of: nav.isProjectFieldFocused)
        // only fires when the value CHANGES, so we need to flip it off
        // first, then back on AFTER SwiftUI has rendered the new view.
        // asyncAfter(0.1) gives SwiftUI time to swap onboardingView →
        // mainLayout and create the new addProjectField.
        nav.isProjectFieldFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.nav.isProjectFieldFocused = true
        }
    }

    // MARK: - Main 2-panel layout (when projects exist)

    private var mainLayout: some View {
        VStack(spacing: 0) {
            HUDPermissionBanner()

            HStack(spacing: 0) {
                projectColumn
                    .frame(width: 140)

                verticalSep

                contentArea
            }
            .frame(maxHeight: .infinity)
            .simultaneousGesture(
                TapGesture().onEnded {
                    if projectFieldFocused { projectFieldFocused = false }
                    if renameFieldFocused { renameFieldFocused = false }
                    if editingProjectIndex != nil {
                        nav.renameProject(at: editingProjectIndex!, to: editingProjectName)
                        editingProjectIndex = nil
                    }
                }
            )

            horizontalSep

            bottomBar
                .frame(height: 32)
        }
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: Content Area — Assigned (top) + Available (bottom)
    // ──────────────────────────────────────────────────────────────

    private var contentArea: some View {
        VStack(spacing: 0) {
            if nav.isAddingWindows {
                availableWindowsList
            } else {
                viewModeLayout
            }
        }
    }

    private var viewModeLayout: some View {
        VStack(spacing: 0) {
            // Top: Horizontal row of compact icons
            assignedWindowsIconsRow
                .frame(height: 90)
            
            horizontalSep
            
            // Bottom: Large preview of the selected window
            selectedWindowLargePreview
        }
    }

    private var selectedWindowLargePreview: some View {
        Group {
            if nav.selectedWindowIndex < nav.windowEntries.count {
                let entry = nav.windowEntries[nav.selectedWindowIndex]
                VStack(spacing: 12) {
                    WindowPreviewView(
                        windowID: entry.windowID,
                        bundleID: entry.appGroup?.appBundleID,
                        title: displayTitle(for: entry),
                        size: CGSize(width: 480, height: 280)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    
                    VStack(spacing: 4) {
                        Text(displayTitle(for: entry))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .layoutPriority(1)
                        
                        HStack(spacing: 6) {
                            AppIconView(bundleID: entry.appGroup?.appBundleID ?? "")
                                .frame(width: 14, height: 14)
                            Text(entry.appGroup?.appName ?? loc.tr("label.unknownApp"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                            Text("·")
                                .foregroundColor(.white.opacity(0.3))
                            Circle()
                                .fill(statusColor(for: entry))
                                .frame(width: 6, height: 6)
                            Text(statusText(for: entry))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
            } else {
                // "+" card is selected/highlighted
                VStack(spacing: 16) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor.opacity(0.85))
                        .shadow(color: .accentColor.opacity(0.3), radius: 8, y: 4)
                    
                    VStack(spacing: 6) {
                        Text(loc.tr("hud.addOpenWindows"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(loc.tr("projects.empty.subtitle"))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var assignedWindowsIconsRow: some View {
        let allEntries = nav.windowEntries
        
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(allEntries, id: \.windowID) { entry in
                    let idx = allEntries.firstIndex(of: entry) ?? 0
                    let isSelected = idx == nav.selectedWindowIndex && nav.focus == .assigned
                    assignedWindowIconCard(entry: entry, index: idx, isSelected: isSelected)
                }
                
                // Add window button (+) at the end of the row
                addWindowButtonCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func assignedWindowIconCard(
        entry: WindowEntry, index: Int, isSelected: Bool
    ) -> some View {
        let projectColor: Color =
            nav.projects.indices.contains(nav.selectedProjectIndex)
            ? Color(hex: nav.projects[nav.selectedProjectIndex].colorHex ?? "#0A84FF")
            : .blue
        
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // App Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? projectColor.opacity(0.18) : .white.opacity(0.06))
                        .frame(width: 48, height: 48)
                    
                    AppIconView(bundleID: entry.appGroup?.appBundleID ?? "")
                        .frame(width: 30, height: 30)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? projectColor.opacity(0.6) : .white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(isSelected ? 0.25 : 0.1), radius: 4, y: 2)
                
                // Minus / Remove button
                Button {
                    nav.unassign(windowID: entry.windowID)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .background(Circle().fill(.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            
            Text(displayTitle(for: entry))
                .font(.system(size: 10, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                .lineLimit(1)
                .frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            nav.selectedWindowIndex = index
            nav.focus = .assigned
        }
    }

    private var addWindowButtonCard: some View {
        let isSelected = nav.selectedWindowIndex == nav.windowEntries.count && nav.focus == .assigned
        
        return Button {
            nav.selectedWindowIndex = nav.windowEntries.count
            nav.isAddingWindows = true
            nav.focus = .available
            nav.selectedAvailableIndex = 0
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : .white.opacity(0.04))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color.accentColor : .white.opacity(0.5))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.15), style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, lineCap: .round, lineJoin: .round, dash: isSelected ? [] : [4]))
                )
                
                Text("+")
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.4))
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
    }

    private var groupedAvailable: [(bundleID: String, appName: String, windows: [TrackedWindow])] {
        Dictionary(grouping: nav.availableWindows, by: { $0.bundleID })
            .map { (bundleID, wins) in
                (bundleID,
                 wins.first?.appName ?? bundleID,
                 wins.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending })
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private var filteredGroupedAvailable: [(bundleID: String, appName: String, windows: [TrackedWindow])] {
        groupedAvailable
    }

    private var availableWindowsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc.tr("hud.addOpenWindows"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(1.0)
                
                Spacer()
                
                if !nav.windowEntries.isEmpty {
                    Button {
                        nav.isAddingWindows = false
                        nav.focus = .assigned
                        nav.selectedWindowIndex = min(nav.selectedWindowIndex, nav.windowEntries.count - 1)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                            Text(loc.tr("wizard.back"))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                }
            }
            .padding(.leading, 14)
            .padding(.top, 8)

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.4))
                    .font(.system(size: 13, weight: .medium))
                
                TextField("Search windows...", text: $nav.windowSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($searchFieldFocused)
                
                if !nav.windowSearchText.isEmpty {
                    Button(action: { nav.windowSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                if filteredGroupedAvailable.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                            .frame(height: 40)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.2))
                        Text("No windows match your search")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredGroupedAvailable, id: \.bundleID) { group in
                            availableAppGroup(bundleID: group.bundleID,
                                              appName: group.appName,
                                              windows: group.windows)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func availableAppGroup(
        bundleID: String, appName: String, windows: [TrackedWindow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AppIconView(bundleID: bundleID)
                    .frame(width: 16, height: 16)
                Text(appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                Text("×\(windows.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.07))
                    .clipShape(Capsule())
                
                if windows.count > 1 {
                    Spacer()
                    Button(action: {
                        nav.assignAll(windows)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                            Text(loc.tr("common.addAll"))
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(windows) { window in
                availableWindowRow(window)
            }
        }
    }

    private func availableWindowRow(_ window: TrackedWindow) -> some View {
        let owner = nav.windowOwners[Int32(bitPattern: UInt32(truncatingIfNeeded: window.id))]
        let absoluteIndex = nav.availableWindows.firstIndex(of: window) ?? -1
        let isKeySel = nav.focus == .available
            && absoluteIndex == nav.selectedAvailableIndex

        return Button {
            nav.selectedAvailableIndex = max(absoluteIndex, 0)
            nav.assign(window)
        } label: {
            HStack(spacing: 6) {
                Text(window.displayTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let owner = owner, !owner.isCurrent {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color(hex: owner.colorHex))
                            .frame(width: 6, height: 6)
                        Text(owner.projectName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.07)))
                }

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .padding(.leading, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isKeySel ? Color.accentColor.opacity(0.18) : .white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(isKeySel ? 0.45 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Keep assignedThumbCell for AssignedThumbCell compatibility
    @ViewBuilder
    private func assignedThumbCell(
        entry: WindowEntry,
        groupIndex: Int,
        entryIdx: Int,
        isWinSel: Bool
    ) -> some View {
        AssignedThumbCell(
            entry: entry,
            isWinSel: isWinSel,
            onSelect: {
                nav.selectedAppGroupIndex = groupIndex
                nav.selectedWindowIndex = entryIdx
                nav.refreshWindowEntries()
            },
            onRemove: {
                nav.unassign(windowID: entry.windowID)
            },
            displayTitle: displayTitle(for: entry)
        )
    }

    // MARK: - Separators

    private var verticalSep: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 0.5)
    }

    private var horizontalSep: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: - Map Button

    private var mapButton: some View {
        Button {
            AppDelegate.switchToMap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 11, weight: .medium))
                Text(loc.tr("hud.map.button"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: Column 1 — Projects (140px)
    // ──────────────────────────────────────────────────────────────

    private var projectColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.tr("column.projects"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .tracking(1.2)
                .padding(.bottom, 8)

            if nav.projects.isEmpty {
                Spacer()
                emptyState(icon: "folder.badge.plus", text: loc.tr("empty.noProjects"))
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(nav.projects, id: \.id) { project in
                            let idx = nav.projects.firstIndex(of: project) ?? 0
                            projectRow(index: idx)
                        }
                    }
                }
            }

            Spacer(minLength: 6)
            addProjectField
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    // Inline "new project" field — lets the user create MULTIPLE projects
    // straight from the HUD (type a name, press Enter).
    private var addProjectField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.accentColor.opacity(0.85))
            TextField(loc.tr("common.newProject"), text: $newProjectName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($projectFieldFocused)
                .onSubmit(createProjectFromOnboarding)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(projectFieldFocused ? 0.12 : 0.06))
        )
    }

    private func projectRow(index: Int) -> some View {
        let project = nav.projects[index]
        let selected = index == nav.selectedProjectIndex
        let color = Color(hex: project.colorHex ?? "#0A84FF")
        let isEditing = editingProjectIndex == index

        return HStack(spacing: 8) {
            // Selection bar
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? color : .clear)
                .frame(width: 4, height: 24)

            if isEditing {
                TextField("", text: $editingProjectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .focused($renameFieldFocused)
                    .onSubmit {
                        nav.renameProject(at: index, to: editingProjectName)
                        editingProjectIndex = nil
                    }
                    .onExitCommand {
                        // Escape → cancel rename
                        editingProjectIndex = nil
                    }
            } else {
                HStack {
                    Text(project.name ?? loc.tr("label.untitled"))
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundColor(selected ? .white : .white.opacity(0.4))
                        .lineLimit(1)
                    
                    if selected {
                        Spacer()
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(4)
                            .background(Circle().fill(.white.opacity(0.12)))
                            .contentShape(Circle())
                            .onTapGesture {
                                nav.deleteProject(at: index)
                            }
                            .padding(.trailing, 2)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? color.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click → start rename
            editingProjectName = project.name ?? ""
            editingProjectIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                renameFieldFocused = true
            }
        }
        .onTapGesture(count: 1) {
            // Clear any text field focus so keyboard navigation works again.
            projectFieldFocused = false
            renameFieldFocused = false
            // Single click → select project (also cancels rename if
            // the user clicks another row).
            if editingProjectIndex != nil && editingProjectIndex != index {
                nav.renameProject(at: editingProjectIndex!, to: editingProjectName)
                editingProjectIndex = nil
            }
            nav.selectedProjectIndex = index
            nav.selectedAppGroupIndex = 0
            nav.selectedWindowIndex = 0
            nav.refreshAppGroups()
        }
    }


    // ──────────────────────────────────────────────────────────────
    // MARK: Bottom Bar
    // ──────────────────────────────────────────────────────────────

    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                shortcutChip(keys: "⌘§", label: loc.tr("shortcut.open"))
                dot
                shortcutChip(keys: "⇥", label: loc.tr("shortcut.focus"))
                dot
                shortcutChip(keys: "↑↓", label: loc.tr("shortcut.window"))
                dot
                shortcutChip(keys: "↩", label: loc.tr("shortcut.jump"))
                dot
                shortcutChip(keys: "⌫", label: loc.tr("shortcut.remove"))
                Spacer()
            }

            HStack {
                Spacer()
                mapButton
                    .padding(.trailing, 14)
            }
        }
    }

    private func shortcutChip(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private var dot: some View {
        Text("·")
            .foregroundColor(.white.opacity(0.2))
            .padding(.horizontal, 8)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ──────────────────────────────────────────────────────────────

    private func sortedEntries(for group: AppGroup) -> [WindowEntry] {
        (group.windowEntries as? Set<WindowEntry>)?
            .sorted { ($0.windowTitle ?? "") < ($1.windowTitle ?? "") } ?? []
    }

    /// Window title for display: the real title, or the app name when the
    /// title is empty/unavailable (common without Screen Recording).
    private func displayTitle(for entry: WindowEntry) -> String {
        let t = entry.windowTitle ?? ""
        if !t.isEmpty { return t }
        return entry.appGroup?.appName ?? loc.tr("label.untitled")
    }

    private func statusColor(for entry: WindowEntry) -> Color {
        guard let lastSeen = entry.lastSeenAt else { return .gray }
        return Date().timeIntervalSince(lastSeen) < 10 ? .green : .orange
    }

    private func statusText(for entry: WindowEntry) -> String {
        guard let lastSeen = entry.lastSeenAt else { return loc.tr("status.unknown") }
        let elapsed = Date().timeIntervalSince(lastSeen)
        if elapsed < 10 { return loc.tr("status.active") }

        let minutes = Int(elapsed / 60)
        if minutes < 1 { return loc.tr("status.idle.seconds", Int(elapsed)) }
        if minutes == 1 { return loc.tr("status.idle.oneMinute") }
        return loc.tr("status.idle.minutes", minutes)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.12))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Assigned Window Thumb Cell
//
// One thumbnail + title + hover-only "−" overlay. The remove button only
// appears while the cell is hovered so the row stays clean at rest.
private struct AssignedThumbCell: View {
    let entry: WindowEntry
    let isWinSel: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let displayTitle: String

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                WindowThumbnailView(
                    windowID: entry.windowID,
                    bundleID: entry.appGroup?.appBundleID
                )
                    .frame(width: 80, height: 55)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.white.opacity(isWinSel ? 0.8 : 0), lineWidth: 1)
                    )

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                            .background(Circle().fill(Color.black.opacity(0.65)))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove from project")
                    .transition(.opacity)
                }
            }

            Text(displayTitle)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .frame(width: 80)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Permission banner
//
// Shown ONLY when Screen Recording is missing. The whole reason the banner
// exists is to make the user trigger the system prompt by an explicit click,
// instead of having macOS pop it spontaneously whenever the background poller
// reads window titles. Self-contained so it can poll its own visibility
// without churning the rest of the HUD.
private struct HUDPermissionBanner: View {
    @ObservedObject private var loc = Localizer.shared
    @State private var screenOK: Bool = CGPreflightScreenCaptureAccess()
    @State private var accessOK: Bool = AppDelegate.hasAccessibilityPermission()

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if screenOK && accessOK { EmptyView() }
        else {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 14))

                Text(bannerMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button(action: grant) {
                    Text(loc.tr("banner.grant"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.10))
            .onReceive(poll) { _ in
                // Re-check so the banner disappears as soon as the user grants
                // the permission in System Settings without us nagging.
                let hasScreen = CGPreflightScreenCaptureAccess()
                if screenOK != hasScreen {
                    screenOK = hasScreen
                }
                let hasAccess = AppDelegate.hasAccessibilityPermission()
                if accessOK != hasAccess {
                    accessOK = hasAccess
                }
            }
        }
    }

    private var bannerMessage: String {
        if !screenOK && !accessOK { return loc.tr("banner.bothMissing") }
        if !screenOK              { return loc.tr("banner.screenMissing") }
        return loc.tr("banner.accessMissing")
    }

    // The act of clicking IS the consent — only here do we let macOS surface
    // its system prompt, plus we open the relevant Settings pane so the user
    // is one click away from the toggle. We re-check preflight INSIDE the
    // handler so a double-click (or a click after the user just granted in
    // Settings) cannot accidentally re-fire the prompt.
    private func grant() {
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CGRequestScreenCaptureAccess()
            }
            AppDelegate.openScreenRecordingSettings()
        } else if !AppDelegate.hasAccessibilityPermission() {
            AppDelegate.requestAccessibilityPermission()
            AppDelegate.openAccessibilitySettings()
        }
    }
}

// MARK: - Cube Logo (NoMoreChaos brand mark)
// Isometric 3D wireframe cube with dots at the top / lower-left / lower-right
// vertices — same geometry as the app icon, drawn as a vector so it stays
// crisp at any size and inherits the requested tint color.
struct CubeLogoView: View {
    var color: Color = .white

    // Normalized vertices, center at (0,0), range roughly -1...1.
    private static let T  = CGPoint(x:  0.00, y: -0.78)
    private static let Sl = CGPoint(x: -0.62, y: -0.40)
    private static let Sr = CGPoint(x:  0.62, y: -0.40)
    private static let Ll = CGPoint(x: -0.62, y:  0.40)
    private static let Lr = CGPoint(x:  0.62, y:  0.40)
    private static let Bb = CGPoint(x:  0.00, y:  0.78)
    private static let Cn = CGPoint(x:  0.00, y:  0.00)

    private static let edges: [(CGPoint, CGPoint)] = [
        (T, Sl), (T, Sr), (Sl, Ll), (Sr, Lr), (Ll, Bb), (Lr, Bb), // outer hexagon
        (Sl, Cn), (Sr, Cn), (Cn, Bb)                              // inner Y
    ]
    private static let dots: [CGPoint] = [T, Ll, Lr]

    private func mapped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let s = min(size.width, size.height)
        let scale = s / 2 * 0.86
        return CGPoint(x: size.width / 2 + p.x * scale,
                       y: size.height / 2 + p.y * scale)
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.045
            let dotR = s * 0.065
            ZStack {
                Path { path in
                    for (a, b) in Self.edges {
                        path.move(to: mapped(a, in: geo.size))
                        path.addLine(to: mapped(b, in: geo.size))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

                ForEach(Self.dots.indices, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: dotR * 2, height: dotR * 2)
                        .position(mapped(Self.dots[i], in: geo.size))
                }
            }
        }
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  MARK: - Setup Wizard                                            ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// First-launch assistant that walks the user through the permissions the
// app needs: Screen Recording (window titles + previews), Launch at Login,
// and an optional Gemini API key. Fully localized (EN/IT).

struct WizardView: View {
    let onFinish: () -> Void

    @ObservedObject private var loc = Localizer.shared
    @State private var step: Int
    @State private var screenGranted: Bool
    @State private var accessGranted: Bool
    @State private var launchAtLogin: Bool

    private let lastStep = 4
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let screen = AppDelegate.hasScreenRecordingPermission()
        let access = AppDelegate.hasAccessibilityPermission()
        let login  = AppDelegate.isLaunchAtLoginEnabled()

        _screenGranted = State(initialValue: screen)
        _accessGranted = State(initialValue: access)
        _launchAtLogin = State(initialValue: login)

        _step = State(initialValue: 0)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            VisualEffectBackground()

            // Liquid-glass iridescent gradient
            LinearGradient(
                colors: [
                    Color(hue: 0.60, saturation: 0.45, brightness: 0.25).opacity(0.40),
                    Color(hue: 0.72, saturation: 0.40, brightness: 0.22).opacity(0.35),
                    Color(hue: 0.85, saturation: 0.35, brightness: 0.20).opacity(0.30),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle radial highlight
            RadialGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 300
            )

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.2), value: step)
                footer
            }
            .padding(30)
        }
        .frame(width: 560, height: 470)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .onReceive(poll) { _ in
            // Permission steps need live status while the user flips toggles
            // in System Settings.
            let hasScreen = AppDelegate.hasScreenRecordingPermission()
            if screenGranted != hasScreen {
                screenGranted = hasScreen
            }
            let hasAccess = AppDelegate.hasAccessibilityPermission()
            if accessGranted != hasAccess {
                accessGranted = hasAccess
            }
            // Auto-advance when the user grants a permission while on its step.
            if step == 1 && hasScreen {
                withAnimation { step = 2 }
            }
            if step == 2 && hasAccess {
                withAnimation { step = 3 }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0:  welcomeStep
        case 1:  screenStep
        case 2:  accessibilityStep
        case 3:  loginStep
        default: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("AppFalcon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            title(loc.tr("wizard.welcome.title"))
            body(loc.tr("wizard.welcome.body"))
            
            languageSelector
            
            Spacer()
        }
    }

    private var languageSelector: some View {
        HStack(spacing: 0) {
            Button(action: {
                Localizer.shared.setLanguage("en")
            }) {
                Text("English")
                    .font(.system(size: 11, weight: loc.lang == "en" ? .bold : .regular))
                    .foregroundColor(loc.lang == "en" ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(loc.lang == "en" ? .white.opacity(0.15) : .clear)
                    )
            }
            .buttonStyle(.plain)

            Button(action: {
                Localizer.shared.setLanguage("it")
            }) {
                Text("Italiano")
                    .font(.system(size: 11, weight: loc.lang == "it" ? .bold : .regular))
                    .foregroundColor(loc.lang == "it" ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(loc.lang == "it" ? .white.opacity(0.15) : .clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.white.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .padding(.top, 4)
    }

    private var screenStep: some View {
        VStack(spacing: 14) {
            Spacer()
            wizardIcon("menubar.dock.rectangle", on: screenGranted)
            title(loc.tr("wizard.screen.title"))
            body(loc.tr("wizard.screen.body"))
            if screenGranted {
                statusBadge(loc.tr("wizard.screen.granted"))
            } else {
                primaryButton(loc.tr("wizard.screen.grant")) {
                    AppDelegate.spawnRelaunchWatcher()
                    // Re-check inside the click so a stale UI state can't
                    // re-prompt: if the user already granted in Settings
                    // before the 1s poll caught up, we just refresh state.
                    guard !CGPreflightScreenCaptureAccess() else {
                        screenGranted = true
                        return
                    }
                    AppDelegate.resetStaleTCC(for: "ScreenCapture")
                    _ = CGRequestScreenCaptureAccess()
                }
                linkButton(loc.tr("wizard.screen.openSettings")) {
                    AppDelegate.spawnRelaunchWatcher()
                    AppDelegate.openScreenRecordingSettings()
                }
                linkButton(loc.tr("wizard.screen.relaunch")) {
                    AppDelegate.spawnRelaunchWatcher()
                    NSApp.terminate(nil)
                }
                troubleshootingTip
            }
            caption(loc.tr("wizard.screen.note"))
            Spacer()
        }
        .onAppear {
            if !CGPreflightScreenCaptureAccess() {
                AppDelegate.resetStaleTCC(for: "ScreenCapture")
                _ = CGRequestScreenCaptureAccess()
            }
        }
        .onChange(of: screenGranted) { granted in
            if granted {
                withAnimation { step = 2 }
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 14) {
            Spacer()
            wizardIcon("macwindow.on.rectangle", on: accessGranted)
            title(loc.tr("wizard.access.title"))
            body(loc.tr("wizard.access.body"))
            if accessGranted {
                statusBadge(loc.tr("wizard.access.granted"))
            } else {
                primaryButton(loc.tr("wizard.access.grant")) {
                    // Re-check inside the click — same idempotence as the
                    // screen step.
                    guard !AppDelegate.hasAccessibilityPermission() else {
                        accessGranted = true
                        return
                    }
                    AppDelegate.resetStaleTCC(for: "Accessibility")
                    AppDelegate.requestAccessibilityPermission()
                    AppDelegate.openAccessibilitySettings()
                }
                linkButton(loc.tr("wizard.access.openSettings")) {
                    AppDelegate.openAccessibilitySettings()
                }
                linkButton(loc.tr("wizard.screen.relaunch")) {
                    AppDelegate.spawnRelaunchWatcher()
                    NSApp.terminate(nil)
                }
                troubleshootingTip
            }
            caption(loc.tr("wizard.access.note"))
            Spacer()
        }
        .onAppear {
            if !AppDelegate.hasAccessibilityPermission() {
                AppDelegate.resetStaleTCC(for: "Accessibility")
                AppDelegate.requestAccessibilityPermission()
            }
        }
        .onChange(of: accessGranted) { granted in
            if granted { withAnimation { step = 3 } }
        }
    }

    private var loginStep: some View {
        VStack(spacing: 14) {
            Spacer()
            wizardIcon("bolt.fill", on: launchAtLogin)
            title(loc.tr("wizard.login.title"))
            body(loc.tr("wizard.login.body"))
            Toggle(loc.tr("wizard.login.toggle"), isOn: Binding(
                get: { launchAtLogin },
                set: { v in launchAtLogin = AppDelegate.setLaunchAtLogin(v) }
            ))
            .toggleStyle(.switch)
            .tint(.accentColor)
            .foregroundColor(.white)
            .frame(maxWidth: 300)
            Spacer()
        }
    }



    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            title(loc.tr("wizard.done.title"))
            body(loc.tr("wizard.done.body"))
            Text("⌘ §")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                linkButton(loc.tr("wizard.back")) {
                    withAnimation { step -= 1 }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(i == step ? 0.9 : 0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            primaryButton(primaryLabel) {
                if step < lastStep { withAnimation { step += 1 } }
                else { onFinish() }
            }
            // Block "Next" until the user has granted the mandatory permission
            // for this step. Steps 1 (Screen) and 2 (Accessibility) are mandatory.
            // The final "Finish" also requires both.
            .opacity(isNextAllowed ? 1.0 : 0.35)
            .allowsHitTesting(isNextAllowed)
        }
    }

    /// Whether the primary "Next" / "Finish" button should be enabled.
    private var isNextAllowed: Bool {
        switch step {
        case 1:         return screenGranted
        case 2:         return accessGranted
        case lastStep:  return screenGranted && accessGranted
        default:        return true
        }
    }

    private var primaryLabel: String {
        if step == 0 { return loc.tr("wizard.start") }
        if step == lastStep { return loc.tr("wizard.finish") }
        return loc.tr("wizard.next")
    }

    // MARK: Building blocks

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 21, weight: .semibold)).foregroundColor(.white)
    }

    private func body(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.4))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
    }

    private var troubleshootingTip: some View {
        Text(loc.tr("wizard.troubleshoot.tip"))
            .font(.system(size: 9))
            .foregroundColor(.orange.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.08)))
            .frame(maxWidth: 400)
    }

    private func wizardIcon(_ name: String, on: Bool) -> some View {
        ZStack {
            Circle()
                .fill(on ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.18))
                .frame(width: 72, height: 72)
            Image(systemName: on ? "checkmark" : name)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(on ? .green : .accentColor)
        }
    }

    private func statusBadge(_ t: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(t).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(.green.opacity(0.15)))
    }

    private func primaryButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 8.5)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.32),
                                    Color.accentColor.opacity(0.12)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.40),
                                    .white.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.accentColor.opacity(0.15), radius: 5, y: 2)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1.5)
        }
        .buttonStyle(.plain)
    }

    private func linkButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.vertical, 7.5)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.20),
                                    .white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}
