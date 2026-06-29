#!/usr/bin/env swift
// diagnose_windows.swift — Diagnostic tool: dumps ALL CGWindowList entries
// to show exactly what macOS reports as "windows" for each running app.
// Run with:  swift diagnose_windows.swift

import Cocoa

guard CGPreflightScreenCaptureAccess() else {
    print("⚠️  Screen Recording permission NOT granted.")
    print("   Cannot read window titles. Requesting access...")
    CGRequestScreenCaptureAccess()
    print("   Grant access in System Preferences → Privacy → Screen Recording, then re-run.")
    exit(1)
}

guard let infoList = CGWindowListCopyWindowInfo(
    [.optionAll], kCGNullWindowID
) as? [[String: Any]] else {
    print("❌ CGWindowListCopyWindowInfo returned nil")
    exit(1)
}

let myPID = ProcessInfo.processInfo.processIdentifier

struct WinInfo {
    let windowID: Int
    let ownerName: String
    let bundleID: String
    let pid: pid_t
    let title: String
    let layer: Int
    let width: CGFloat
    let height: CGFloat
    let x: CGFloat
    let y: CGFloat
    let onscreen: Bool
    let alpha: Double
}

var appWindows: [String: [WinInfo]] = [:]
var totalLayer0 = 0

for info in infoList {
    guard
        let windowNumber = info[kCGWindowNumber as String] as? Int,
        let ownerName    = info[kCGWindowOwnerName as String] as? String,
        let pid          = info[kCGWindowOwnerPID as String] as? pid_t,
        let layer        = info[kCGWindowLayer as String] as? Int
    else { continue }
    
    guard layer == 0 else { continue }
    guard pid != myPID else { continue }
    
    let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
    guard alpha > 0.1 else { continue }
    
    let app = NSRunningApplication(processIdentifier: pid)
    if let app = app, app.activationPolicy == .prohibited { continue }
    
    let sanitizedOwner = ownerName.replacingOccurrences(of: " ", with: "-").lowercased()
    let bundleID = app?.bundleIdentifier ?? "local.utility.\(sanitizedOwner)"
    
    var bounds = CGRect.zero
    if let b = info[kCGWindowBounds as String] {
        CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &bounds)
    }
    
    guard bounds.width >= 120, bounds.height >= 120 else { continue }
    
    let title = info[kCGWindowName as String] as? String ?? ""
    let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    
    // Same filters as NoMoreChaos
    if title.isEmpty && !onscreen { continue }
    guard !title.isEmpty || (bounds.width >= 400 && bounds.height >= 300) else { continue }
    
    totalLayer0 += 1
    
    let w = WinInfo(
        windowID: windowNumber,
        ownerName: ownerName,
        bundleID: bundleID,
        pid: pid,
        title: title,
        layer: layer,
        width: bounds.width,
        height: bounds.height,
        x: bounds.origin.x,
        y: bounds.origin.y,
        onscreen: onscreen,
        alpha: alpha
    )
    
    appWindows[bundleID, default: []].append(w)
}

print("=" * 80)
print("🔍 DIAGNOSTICA FINESTRE NoMoreChaos — \(Date())")
print("=" * 80)
print("")
print("Totale finestre rilevate (layer 0, >= 120x120, visibili): \(totalLayer0)")
print("")

// Sort apps by name, show those with multiple windows first
let sorted = appWindows.sorted { a, b in
    if a.value.count != b.value.count { return a.value.count > b.value.count }
    return a.key < b.key
}

for (bundleID, windows) in sorted {
    let appName = windows.first?.ownerName ?? "?"
    let marker = windows.count > 1 ? "⚡ \(windows.count) FINESTRE" : "1 finestra"
    print("┌─ \(appName) [\(bundleID)] — \(marker)")
    for (i, w) in windows.enumerated() {
        let isLast = i == windows.count - 1
        let prefix = isLast ? "└──" : "├──"
        let titleDisplay = w.title.isEmpty ? "(titolo vuoto)" : "\"\(w.title)\""
        let screenStr = w.onscreen ? "ON-SCREEN" : "OFF-SCREEN"
        print("  \(prefix) ID=\(w.windowID)  \(titleDisplay)  [\(Int(w.width))×\(Int(w.height))]  pos=(\(Int(w.x)),\(Int(w.y)))  \(screenStr)")
    }
    print("")
}

// Summary for apps with multiple windows
let multiWindow = sorted.filter { $0.value.count > 1 }
if multiWindow.isEmpty {
    print("⚠️  NESSUNA APP ha più di una finestra aperta al momento.")
    print("   Per testare, apri due finestre della stessa app (es. due finestre Safari)")
    print("   e riesegui questo script.")
} else {
    print("=" * 80)
    print("📊 RIEPILOGO APP CON FINESTRE MULTIPLE:")
    for (bundleID, windows) in multiWindow {
        let appName = windows.first?.ownerName ?? "?"
        let titles = windows.map { $0.title.isEmpty ? "(vuoto)" : $0.title }
        let uniqueTitles = Set(titles)
        print("  • \(appName): \(windows.count) finestre")
        if uniqueTitles.count < titles.count {
            print("    ⚠️  ATTENZIONE: \(titles.count - uniqueTitles.count + 1) finestre con titolo IDENTICO!")
        }
        for t in titles {
            print("    → \(t)")
        }
    }
}

// Helper
func *(lhs: String, rhs: Int) -> String {
    String(repeating: lhs, count: rhs)
}
