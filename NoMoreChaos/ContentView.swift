import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var windowTracker: WindowTracker
    @ObservedObject private var loc = Localizer.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Project.sortOrder, ascending: true)],
        animation: .default
    )
    private var projects: FetchedResults<Project>

    @State private var newProjectName = ""

    private var coreDataManager: CoreDataManager {
        CoreDataManager(context: viewContext)
    }

    var body: some View {
        HSplitView {
            windowListPanel
            projectListPanel
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: - Left Panel: Detected Windows

    private var windowListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "macwindow.on.rectangle")
                    .foregroundColor(.accentColor)
                Text(loc.tr("windows.header"))
                    .font(.headline)
                Spacer()
                Text("\(windowTracker.windows.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.bottom, 4)

            if windowTracker.windows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(loc.tr("windows.empty.title"))
                        .foregroundColor(.secondary)
                    Text(loc.tr("windows.empty.permission"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(loc.tr("windows.openSettings")) {
                        AppDelegate.openScreenRecordingSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(windowTracker.windows) { window in
                        windowRow(window)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding()
        .frame(minWidth: 450)
    }

    private func windowRow(_ window: TrackedWindow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName)
                    .font(.system(.body, weight: .medium))
                Text(window.displayTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(window.bundleID)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            if !projects.isEmpty {
                assignmentPicker(for: window)
            }
        }
        .padding(.vertical, 4)
    }

    private func assignmentPicker(for window: TrackedWindow) -> some View {
        let currentProject = coreDataManager.projectForWindow(windowID: Int32(bitPattern: UInt32(truncatingIfNeeded: window.id)))

        return Picker("", selection: Binding<String>(
            get: {
                currentProject?.id?.uuidString ?? "__none__"
            },
            set: { newValue in
                if newValue == "__none__" {
                    coreDataManager.removeWindowAssignment(windowID: Int32(bitPattern: UInt32(truncatingIfNeeded: window.id)))
                } else if let project = projects.first(where: {
                    $0.id?.uuidString == newValue
                }) {
                    coreDataManager.assignWindow(
                        windowID: Int32(bitPattern: UInt32(truncatingIfNeeded: window.id)),
                        title: window.title,
                        bundleID: window.bundleID,
                        appName: window.appName,
                        x: window.x,
                        y: window.y,
                        to: project
                    )
                }
            }
        )) {
            Text(loc.tr("picker.none")).tag("__none__")
            ForEach(projects) { project in
                HStack {
                    Circle()
                        .fill(Color(hex: project.colorHex ?? "#0A84FF"))
                        .frame(width: 8, height: 8)
                    Text(project.name ?? loc.tr("label.untitled"))
                }
                .tag(project.id?.uuidString ?? "")
            }
        }
        .labelsHidden()
        .frame(width: 160)
    }

    // MARK: - Right Panel: Projects

    private var projectListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.orange)
                Text(loc.tr("projects.header"))
                    .font(.headline)
            }

            HStack(spacing: 8) {
                TextField(loc.tr("projects.newPlaceholder"), text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createProject() }

                Button(action: createProject) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 4)

            if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(loc.tr("projects.empty.title"))
                        .foregroundColor(.secondary)
                    Text(loc.tr("projects.empty.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(projects) { project in
                        projectSection(project)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

        }
        .padding()
        .frame(minWidth: 350)
    }

    private func projectSection(_ project: Project) -> some View {
        DisclosureGroup {
            let groups = (project.appGroups as? Set<AppGroup>)?
                .sorted { ($0.appName ?? "") < ($1.appName ?? "") } ?? []

            if groups.isEmpty {
                Text(loc.tr("project.noWindowsAssigned"))
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.leading)
            } else {
                ForEach(groups, id: \.self) { group in
                    appGroupRow(group)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: project.colorHex ?? "#0A84FF"))
                    .frame(width: 10, height: 10)
                Text(project.name ?? loc.tr("label.untitled"))
                    .font(.system(.body, weight: .semibold))
                Spacer()
                Button(role: .destructive) {
                    withAnimation {
                        coreDataManager.deleteProject(project)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func appGroupRow(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "app.fill")
                    .foregroundColor(.accentColor)
                Text(group.appName ?? loc.tr("label.unknownApp"))
                    .font(.system(.callout, weight: .medium))
            }

            let entries = (group.windowEntries as? Set<WindowEntry>)?
                .filter { $0.isActive }
                .sorted { ($0.windowTitle ?? "") < ($1.windowTitle ?? "") } ?? []

            ForEach(entries, id: \.self) { entry in
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(entry.windowTitle?.isEmpty == false
                         ? entry.windowTitle!
                         : (group.appName ?? loc.tr("label.untitled")))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation {
            coreDataManager.createProject(name: name)
            newProjectName = ""
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(WindowTracker.shared)
    }
}
