import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Helper: String multiplication
extension String {
    static func * (lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

// MARK: - Screenshot via ScreenCaptureKit

/// Attempt to capture a single window by CGWindowID using ScreenCaptureKit.
/// Returns (success, width, height).
func captureWindow(cgWindowID: CGWindowID) async -> (Bool, Int, Int) {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == cgWindowID }) else {
            return (false, 0, 0)
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width) > 0 ? Int(scWindow.frame.width) : 200
        config.height = Int(scWindow.frame.height) > 0 ? Int(scWindow.frame.height) : 200
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (true, image.width, image.height)
    } catch {
        return (false, 0, 0)
    }
}

// MARK: - Main

func main() async {
    guard let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        print("❌ Failed to enumerate windows.")
        return
    }

    print("=" * 80)
    print("NoMoreChaos Window ID Diagnostic")
    print("=" * 80)
    print("Total windows enumerated: \(windowInfoList.count)")
    print("")

    // Counters
    var totalPassed = 0
    var totalScreenshotSuccess = 0
    var totalScreenshotFail = 0
    var roundTripMismatches: [(Int, CGWindowID)] = []

    for info in windowInfoList {
        // Extract basic properties
        guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0.0
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? "<unknown>"
        let windowName = info[kCGWindowName as String] as? String ?? "<no name>"
        let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? -1

        // Extract bounds
        guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let width = boundsDict["Width"] as? Double,
              let height = boundsDict["Height"] as? Double,
              let x = boundsDict["X"] as? Double,
              let y = boundsDict["Y"] as? Double else {
            continue
        }

        // Apply NoMoreChaos filters
        guard layer == 0 else { continue }
        guard alpha > 0.1 else { continue }
        guard width >= 120 else { continue }
        guard height >= 120 else { continue }

        totalPassed += 1

        // --- Conversion chain (same as NoMoreChaos) ---
        // Step 1: Original windowNumber (Int from CGWindowListCopyWindowInfo)
        let originalWindowNumber = windowNumber

        // Step 2: Convert to Int32 via UInt32 truncation (NoMoreChaos storage)
        let storedInt32 = Int32(bitPattern: UInt32(truncatingIfNeeded: windowNumber))

        // Step 3: Convert back to CGWindowID for capture
        let convertedBackCGWindowID = CGWindowID(bitPattern: storedInt32)

        // Step 4: Check round-trip
        let roundTripMatch = originalWindowNumber == Int(convertedBackCGWindowID)

        // Step 5: Attempt screenshot using ScreenCaptureKit
        let (screenshotSucceeded, screenshotWidth, screenshotHeight) = await captureWindow(cgWindowID: convertedBackCGWindowID)

        if screenshotSucceeded {
            totalScreenshotSuccess += 1
        } else {
            totalScreenshotFail += 1
        }

        // Print results
        let mismatchFlag = roundTripMatch ? "" : " ⚠️  MISMATCH!"
        print("─" * 60)
        print("Window #\(totalPassed): \(ownerName) — \"\(windowName)\"")
        print("  PID:                  \(ownerPID)")
        print("  Position:             (\(x), \(y))  Size: \(width) × \(height)")
        print("  Layer: \(layer)  Alpha: \(String(format: "%.2f", alpha))")
        print("  ───── ID Conversion Chain ─────")
        print("  Original (Int):       \(originalWindowNumber)")
        print("  → UInt32(trunc):      \(UInt32(truncatingIfNeeded: windowNumber))")
        print("  → Int32(bitPattern):  \(storedInt32)")
        print("  → CGWindowID(back):   \(convertedBackCGWindowID)")
        print("  Round-trip match:     \(roundTripMatch)\(mismatchFlag)")
        print("  ───── Screenshot ─────")
        print("  Screenshot:           \(screenshotSucceeded ? "✅ OK" : "❌ FAILED")  \(screenshotSucceeded ? "(\(screenshotWidth)×\(screenshotHeight))" : "")")

        if !roundTripMatch {
            roundTripMismatches.append((originalWindowNumber, convertedBackCGWindowID))
        }
    }

    // Summary
    print("")
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print("Windows passing filters:  \(totalPassed)")
    print("Screenshots succeeded:    \(totalScreenshotSuccess)")
    print("Screenshots failed:       \(totalScreenshotFail)")
    print("")

    if roundTripMismatches.isEmpty {
        print("✅ All round-trip conversions match. No ID corruption detected.")
    } else {
        print("⚠️  ROUND-TRIP MISMATCHES DETECTED: \(roundTripMismatches.count)")
        for (original, converted) in roundTripMismatches {
            print("  Original: \(original)  →  Converted back: \(converted)")
            print("    Difference: \(Int(converted) - original)")
        }
    }

    print("")
    print("Done.")
}

// Run
await main()
