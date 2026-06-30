import Cocoa
import CoreGraphics

// MARK: - Diagnostic: CGWindowListCreateImage per-window test

let targetApps: Set<String> = ["Safari", "Antigravity", "Google Chrome", "Claude"]

struct WindowResult {
    let windowID: CGWindowID
    let ownerName: String
    let windowName: String
    let isOnScreen: Bool
    let imageResult: String // "nil" or "WxH"
    let success: Bool
}

func runDiagnostic() {
    print("=" * 70)
    print("CGWindowListCreateImage Diagnostic")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Date: \(Date())")
    print("=" * 70)
    print()

    // 1. Enumerate all windows
    guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        print("ERROR: CGWindowListCopyWindowInfo returned nil!")
        return
    }

    print("Total windows found: \(windowList.count)")
    print()

    var results: [WindowResult] = []

    for windowInfo in windowList {
        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
        let windowName = windowInfo[kCGWindowName as String] as? String ?? ""
        let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID ?? 0

        // Filter: only target apps, and only windows with a title
        guard targetApps.contains(ownerName), !windowName.isEmpty else {
            continue
        }

        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
        let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
        let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 0.0
        let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
        let boundsStr: String
        if let b = bounds {
            let x = b["X"] as? Double ?? 0
            let y = b["Y"] as? Double ?? 0
            let w = b["Width"] as? Double ?? 0
            let h = b["Height"] as? Double ?? 0
            boundsStr = "(\(Int(x)),\(Int(y))) \(Int(w))x\(Int(h))"
        } else {
            boundsStr = "unknown"
        }

        print("─" * 60)
        print("Window ID: \(windowID)")
        print("  Owner:     \(ownerName)")
        print("  Title:     \(windowName)")
        print("  OnScreen:  \(isOnScreen)")
        print("  Layer:     \(layer)")
        print("  Alpha:     \(alpha)")
        print("  Bounds:    \(boundsStr)")

        // 2. Try CGWindowListCreateImage
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        )

        let imageResult: String
        let success: Bool
        if let img = image {
            let w = img.width
            let h = img.height
            imageResult = "\(w)x\(h)"
            success = true
            print("  CGImage:   ✅ \(w)x\(h) pixels")
        } else {
            imageResult = "nil"
            success = false
            print("  CGImage:   ❌ nil (capture failed)")
        }

        results.append(WindowResult(
            windowID: windowID,
            ownerName: ownerName,
            windowName: windowName,
            isOnScreen: isOnScreen,
            imageResult: imageResult,
            success: success
        ))
    }

    // 3. Summary
    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)

    if results.isEmpty {
        print("No matching windows found from: \(targetApps.sorted().joined(separator: ", "))")
        print("Make sure at least one of these apps is running with a visible window.")
        return
    }

    let successCount = results.filter { $0.success }.count
    let failCount = results.filter { !$0.success }.count

    print("Total matching windows: \(results.count)")
    print("  ✅ Successful captures: \(successCount)")
    print("  ❌ Failed captures (nil): \(failCount)")
    print()

    // Group by app
    let grouped = Dictionary(grouping: results, by: { $0.ownerName })
    for (app, appResults) in grouped.sorted(by: { $0.key < $1.key }) {
        let appSuccess = appResults.filter { $0.success }.count
        let appFail = appResults.filter { !$0.success }.count
        print("\(app): \(appSuccess) ok, \(appFail) failed")
        for r in appResults {
            let status = r.success ? "✅ \(r.imageResult)" : "❌ nil"
            let screenStr = r.isOnScreen ? "on-screen" : "off-screen"
            let titleTrunc = String(r.windowName.prefix(40))
            print("    WID \(r.windowID) [\(screenStr)] \(status) — \"\(titleTrunc)\"")
        }
    }

    print()
    if failCount == results.count {
        print("⚠️  ALL captures returned nil.")
        print("   This likely means Screen Recording permission is NOT granted.")
        print("   Go to System Settings → Privacy & Security → Screen Recording")
        print("   and ensure your terminal / Swift process is allowed.")
    } else if failCount > 0 {
        print("⚠️  Some captures returned nil.")
        print("   Off-screen or minimized windows often return nil with CGWindowListCreateImage.")
    } else {
        print("✅ All captures succeeded! CGWindowListCreateImage works for these windows.")
    }
}

// Helper to repeat strings
extension String {
    static func * (lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

runDiagnostic()
