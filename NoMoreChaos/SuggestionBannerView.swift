import SwiftUI
import AppKit

// ╔══════════════════════════════════════════════════════════════════╗
// ║  Suggestion Model                                                ║
// ╚══════════════════════════════════════════════════════════════════╝

struct AISuggestion {
    let windowID: Int32
    let windowTitle: String
    let bundleID: String
    let appName: String
    let suggestedProjectName: String
    let x: Double
    let y: Double
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  SuggestionBannerView (SwiftUI pill)                             ║
// ╚══════════════════════════════════════════════════════════════════╝

struct SuggestionBannerView: View {
    let suggestion: AISuggestion
    let onAssign: () -> Void
    let onIgnore: () -> Void
    @ObservedObject private var loc = Localizer.shared

    var body: some View {
        HStack(spacing: 14) {
            // Icon + label
            Text("💡")
                .font(.system(size: 18))

            Text(loc.tr("suggestion.prefix"))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.65))

            Text(suggestion.suggestedProjectName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            // For window context
            Text("\(loc.tr("suggestion.for")) \(suggestion.appName)")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)

            Spacer().frame(width: 4)

            // Buttons
            Button(action: onAssign) {
                Text(loc.tr("suggestion.assign"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "#0A84FF"))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onIgnore) {
                Text(loc.tr("suggestion.ignore"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            ZStack {
                VisualEffectBackground()
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.25))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  SuggestionPanel (floating NSPanel)                              ║
// ╚══════════════════════════════════════════════════════════════════╝

final class SuggestionPanel: NSPanel {
    private var autoDismissTimer: Timer?

    convenience init(placeholder: Bool = false) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    /// Shows the pill with slide-up + fade; auto-dismisses after 8 s.
    func show(suggestion: AISuggestion, onAssign: @escaping () -> Void) {
        autoDismissTimer?.invalidate()

        let banner = SuggestionBannerView(
            suggestion: suggestion,
            onAssign: { [weak self] in
                onAssign()
                self?.dismiss()
            },
            onIgnore: { [weak self] in
                self?.dismiss()
            }
        )

        let hosting = NSHostingView(rootView: banner)
        contentView = hosting

        // Size to fit content
        let fitted = hosting.fittingSize
        setContentSize(fitted)

        // Position: bottom center, 40px above bottom edge
        if let screen = NSScreen.main {
            let x = (screen.frame.width - fitted.width) / 2
            setFrameOrigin(NSPoint(x: x, y: 20)) // start 20px lower for slide-up
        }

        alphaValue = 0
        orderFrontRegardless()

        // Slide up + fade in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrameOrigin(NSPoint(
                x: frame.origin.x,
                y: 40                           // final resting position
            ))
        }

        // Auto-dismiss after 8 seconds
        autoDismissTimer = Timer.scheduledTimer(
            withTimeInterval: 8.0, repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrameOrigin(NSPoint(
                x: frame.origin.x,
                y: frame.origin.y - 20          // slide back down
            ))
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  SuggestionManager (coordinates WindowTracker → Gemini → banner) ║
// ╚══════════════════════════════════════════════════════════════════╝

final class SuggestionManager {
    static let shared = SuggestionManager()

    private let panel = SuggestionPanel(placeholder: true)

    /// IDs we've already queried so we don't spam Gemini.
    private var queriedWindowIDs: Set<Int32> = []

    private init() {}

    /// Called by WindowTracker when a genuinely new window appears.
    func evaluateNewWindow(_ window: TrackedWindow) {
        let wid = Int32(bitPattern: UInt32(truncatingIfNeeded: window.id))

        // Don't ask twice for the same window
        guard !queriedWindowIDs.contains(wid) else { return }
        queriedWindowIDs.insert(wid)

        let context = PersistenceController.shared.container.viewContext
        let manager = CoreDataManager(context: context)

        // Skip if already assigned to a project
        if manager.projectForWindow(windowID: wid) != nil { return }

        // Gather project names
        let projects = manager.fetchProjects()
        guard !projects.isEmpty else { return }
        let names = projects.compactMap { $0.name }

        Task {
            // Capture screenshot
            guard let image = await NavigationController.captureWindowImageAsync(
                windowID: wid
            ) else { return }

            guard let suggestedName = await GeminiService.shared.suggestProject(
                image: image,
                projectNames: names
            ) else { return }

            let suggestion = AISuggestion(
                windowID: wid,
                windowTitle: window.title,
                bundleID: window.bundleID,
                appName: window.appName,
                suggestedProjectName: suggestedName,
                x: window.x,
                y: window.y
            )

            await MainActor.run {
                // Re-fetch on the main context instead of capturing the
                // non-Sendable `projects` / `manager` across the Task
                // boundary (an error under the Swift 6 language mode).
                let mgr = CoreDataManager(
                    context: PersistenceController.shared.container.viewContext
                )
                self.panel.show(suggestion: suggestion) {
                    // "Assegna" tapped → persist the assignment
                    guard let project = mgr.fetchProjects().first(where: {
                        $0.name == suggestedName
                    }) else { return }
                    mgr.assignWindow(
                        windowID: suggestion.windowID,
                        title: suggestion.windowTitle,
                        bundleID: suggestion.bundleID,
                        appName: suggestion.appName,
                        x: suggestion.x,
                        y: suggestion.y,
                        to: project
                    )
                }
            }
        }
    }
}
