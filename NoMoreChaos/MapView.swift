import SwiftUI
import AppKit

// ╔══════════════════════════════════════════════════════════════════╗
// ║  Position Tracking — preference key for connection lines         ║
// ╚══════════════════════════════════════════════════════════════════╝

private struct NodeAnchor: Equatable {
    let id: String
    let center: CGPoint
}

private struct NodeAnchorKey: PreferenceKey {
    static var defaultValue: [NodeAnchor] = []
    static func reduce(value: inout [NodeAnchor], nextValue: () -> [NodeAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PositionReporter: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: NodeAnchorKey.self,
                    value: [NodeAnchor(
                        id: id,
                        center: CGPoint(
                            x: geo.frame(in: .named("mapSpace")).midX,
                            y: geo.frame(in: .named("mapSpace")).midY
                        )
                    )]
                )
            }
        )
    }
}

private extension View {
    func reportPosition(id: String) -> some View {
        modifier(PositionReporter(id: id))
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  MapView                                                         ║
// ╚══════════════════════════════════════════════════════════════════╝

struct MapView: View {
    let projects: [Project]
    let onJump: (Int32) -> Void
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var selectedProjectID: UUID?
    @State private var positions: [String: CGPoint] = [:]
    @ObservedObject private var loc = Localizer.shared

    var body: some View {
        ZStack {
            // Frosted-glass backdrop (the panel itself is transparent now).
            VisualEffectBackground()

            // Liquid-glass iridescent gradient — premium translucent feel
            // that lets the desktop bleed through the frosted material.
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: 0.60, saturation: 0.45, brightness: 0.25).opacity(0.50),
                        Color(hue: 0.72, saturation: 0.40, brightness: 0.22).opacity(0.45),
                        Color(hue: 0.85, saturation: 0.35, brightness: 0.20).opacity(0.40),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Subtle radial highlight in the top-center for depth
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 50,
                    endRadius: 500
                )
            }

            // Connection lines (behind everything)
            connectionsCanvas

            VStack(spacing: 0) {
                header
                    .padding(.top, 40)

                Spacer()

                if projects.isEmpty {
                    emptyState
                } else {
                    treeContent
                }

                Spacer()
            }
        }
        .coordinateSpace(name: "mapSpace")
        .onPreferenceChange(NodeAnchorKey.self) { anchors in
            var dict: [String: CGPoint] = [:]
            for a in anchors { dict[a.id] = a.center }
            
            var hasChangedSignificantly = false
            if dict.count != positions.count {
                hasChangedSignificantly = true
            } else {
                for (id, newPoint) in dict {
                    if let oldPoint = positions[id] {
                        let dx = abs(newPoint.x - oldPoint.x)
                        let dy = abs(newPoint.y - oldPoint.y)
                        if dx > 0.5 || dy > 0.5 {
                            hasChangedSignificantly = true
                            break
                        }
                    } else {
                        hasChangedSignificantly = true
                        break
                    }
                }
            }
            
            if hasChangedSignificantly {
                positions = dict
            }
        }
        .onAppear {
            withAnimation(.spring(dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Text(loc.tr("map.header"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.40))
                .tracking(1.0)
            Spacer()
        }
        .overlay(alignment: .leading) {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text(loc.tr("map.back"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.leading, 30)
        }
        .overlay(alignment: .trailing) {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Text("Esc")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.12))
                        )
                    Text(loc.tr("map.close"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 40)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.1))
            Text(loc.tr("map.empty"))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: - Tree Content

    private var treeContent: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            HStack(alignment: .top, spacing: 80) {
                ForEach(projects, id: \.id) { project in
                    let idx = projects.firstIndex(of: project) ?? 0
                    projectColumn(project: project, globalIndex: idx)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Project Column

    private func projectColumn(project: Project, globalIndex: Int) -> some View {
        let groups = sortedGroups(for: project)
        let totalWindows = groups.reduce(0) {
            $0 + (($1.windowEntries as? Set<WindowEntry>)?.count ?? 0)
        }
        let isSelected = selectedProjectID == project.id
        let pID = project.id?.uuidString ?? "\(globalIndex)"

        return VStack(spacing: 36) {
            // Project node
            ProjectNodeView(
                project: project,
                totalWindows: totalWindows,
                isSelected: isSelected
            )
            .reportPosition(id: "p-\(pID)")
            .onTapGesture {
                withAnimation(.spring(dampingFraction: 0.7)) {
                    selectedProjectID = isSelected ? nil : project.id
                }
            }
            .staggerIn(appeared: appeared,
                        delay: Double(globalIndex) * 0.05)

            // App groups
            ForEach(Array(groups.enumerated()), id: \.offset) { gIdx, group in
                appGroupColumn(
                    group: group,
                    projectID: pID,
                    globalIndex: globalIndex,
                    groupIndex: gIdx
                )
            }
        }
    }

    // MARK: - App Group Column

    private func appGroupColumn(
        group: AppGroup,
        projectID: String,
        globalIndex: Int,
        groupIndex: Int
    ) -> some View {
        let entries = sortedEntries(for: group)
        let gID = "\(group.appBundleID ?? group.objectID.uriRepresentation().absoluteString)-\(projectID)"

        return VStack(spacing: 24) {
            AppGroupNodeView(group: group, windowCount: entries.count)
                .reportPosition(id: "g-\(gID)")
                .staggerIn(appeared: appeared,
                            delay: Double(globalIndex) * 0.05
                                 + Double(groupIndex + 1) * 0.03)

            // Window cards
            HStack(spacing: 12) {
                ForEach(entries, id: \.windowID) { entry in
                    let wIdx = entries.firstIndex(of: entry) ?? 0
                    WindowCardView(entry: entry) {
                        onJump(entry.windowID)
                        onDismiss()
                    }
                    .reportPosition(id: "w-\(entry.windowID)")
                    .staggerIn(appeared: appeared,
                                delay: Double(globalIndex) * 0.05
                                     + Double(groupIndex + 1) * 0.03
                                     + Double(wIdx + 1) * 0.02)
                }
            }
        }
    }

    // MARK: - Connection Lines Canvas

    private var connectionsCanvas: some View {
        Canvas { context, _ in
            for project in projects {
                let pID = "p-\(project.id?.uuidString ?? "")"
                guard let pPos = positions[pID] else { continue }

                let groups = sortedGroups(for: project)

                for group in groups {
                    let gID = "g-\(group.appBundleID ?? group.objectID.uriRepresentation().absoluteString)-\(project.id?.uuidString ?? "")"
                    guard let gPos = positions[gID] else { continue }

                    // Solid bezier: project → group
                    drawCurve(
                        in: &context,
                        from: CGPoint(x: pPos.x, y: pPos.y + 30),
                        to:   CGPoint(x: gPos.x, y: gPos.y - 22),
                        color: .white.opacity(0.2),
                        lineWidth: 0.5,
                        dashed: false
                    )

                    // Dashed bezier: group → each window
                    let entries = sortedEntries(for: group)
                    for entry in entries {
                        let wID = "w-\(entry.windowID)"
                        guard let wPos = positions[wID] else { continue }

                        drawCurve(
                            in: &context,
                            from: CGPoint(x: gPos.x, y: gPos.y + 22),
                            to:   CGPoint(x: wPos.x, y: wPos.y - 35),
                            color: .white.opacity(0.12),
                            lineWidth: 0.5,
                            dashed: true
                        )
                    }
                }
            }
        }
    }

    private func drawCurve(
        in context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        color: Color,
        lineWidth: CGFloat,
        dashed: Bool
    ) {
        var path = Path()
        path.move(to: from)
        let midY = (from.y + to.y) / 2
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x, y: midY),
            control2: CGPoint(x: to.x,   y: midY)
        )
        let style = dashed
            ? StrokeStyle(lineWidth: lineWidth, dash: [4, 3])
            : StrokeStyle(lineWidth: lineWidth)
        context.stroke(path, with: .color(color), style: style)
    }

    // MARK: - Data Helpers

    private func sortedGroups(for project: Project) -> [AppGroup] {
        (project.appGroups as? Set<AppGroup>)?
            .sorted { ($0.appName ?? "") < ($1.appName ?? "") } ?? []
    }

    private func sortedEntries(for group: AppGroup) -> [WindowEntry] {
        (group.windowEntries as? Set<WindowEntry>)?
            .filter { $0.isActive }
            .sorted { ($0.windowTitle ?? "") < ($1.windowTitle ?? "") } ?? []
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  Stagger Animation Modifier                                      ║
// ╚══════════════════════════════════════════════════════════════════╝

private struct StaggerModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.8)
            .animation(
                .spring(dampingFraction: 0.7).delay(delay),
                value: appeared
            )
    }
}

private extension View {
    func staggerIn(appeared: Bool, delay: Double) -> some View {
        modifier(StaggerModifier(appeared: appeared, delay: delay))
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  Project Node                                                     ║
// ╚══════════════════════════════════════════════════════════════════╝

private struct ProjectNodeView: View {
    let project: Project
    let totalWindows: Int
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(project.name ?? Localizer.shared.tr("label.untitled"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(totalWindows == 1
                 ? Localizer.shared.tr("window.count.one")
                 : Localizer.shared.tr("window.count.other", totalWindows))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(width: 160, height: 60)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: project.colorHex ?? "#0A84FF").opacity(0.15))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(hex: project.colorHex ?? "#0A84FF").opacity(0.5),
                            .white.opacity(0.15),
                            Color(hex: project.colorHex ?? "#0A84FF").opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .shadow(color: Color(hex: project.colorHex ?? "#0A84FF").opacity(isSelected ? 0.35 : 0.1),
                radius: isSelected ? 12 : 4)
        .animation(.spring(dampingFraction: 0.7), value: isSelected)
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  App Group Node                                                   ║
// ╚══════════════════════════════════════════════════════════════════╝

private struct AppGroupNodeView: View {
    let group: AppGroup
    let windowCount: Int

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(bundleID: group.appBundleID ?? "")
                .frame(width: 16, height: 16)

            Text(group.appName ?? Localizer.shared.tr("label.unknownApp"))
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)

            Text("×\(windowCount)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(width: 120, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  Window Card                                                      ║
// ╚══════════════════════════════════════════════════════════════════╝

private struct WindowCardView: View {
    let entry: WindowEntry
    let onTap: () -> Void

    @State private var thumbnail: NSImage?
    @State private var dragOffset: CGSize = .zero

    private var cardTitle: String {
        let t = entry.windowTitle ?? ""
        return t.isEmpty ? (entry.appGroup?.appName ?? Localizer.shared.tr("label.untitled")) : t
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail background
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.white.opacity(0.04))
                        .overlay {
                            Image(systemName: "macwindow")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.1))
                        }
                }
            }

            // Dark gradient overlay at bottom
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .center
            )

            // Title
            Text(cardTitle)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .frame(width: 100, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .offset(dragOffset)
        .gesture(dragGesture)
        .onTapGesture { onTap() }
        .onAppear { captureThumbnail() }
    }

    // Drag: visual feedback only (reassignment in future phase)
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { _ in
                withAnimation(.spring(dampingFraction: 0.6)) {
                    dragOffset = .zero
                }
            }
    }

    private func captureThumbnail() {
        let wid = entry.windowID
        Task {
            let img = await NavigationController.captureWindowImageAsync(windowID: wid)
            await MainActor.run { thumbnail = img }
        }
    }
}
