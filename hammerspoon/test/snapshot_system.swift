import AppKit
import CoreGraphics
import Foundation

let targetBundles: Set<String> = ["com.google.Chrome", "com.apple.Safari", "md.obsidian"]
let applications = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, String)? in
    guard let bundleID = app.bundleIdentifier else { return nil }
    return (app.processIdentifier, bundleID)
})

let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let selectedWindows = windows.compactMap { window -> [String: Any]? in
    guard
        let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let bundleID = applications[pid],
        targetBundles.contains(bundleID),
        let windowID = window[kCGWindowNumber as String] as? NSNumber,
        let bounds = window[kCGWindowBounds as String] as? [String: NSNumber]
    else { return nil }

    let rect: [String: Double] = [
        "x": bounds["X"]?.doubleValue ?? 0,
        "y": bounds["Y"]?.doubleValue ?? 0,
        "w": bounds["Width"]?.doubleValue ?? 0,
        "h": bounds["Height"]?.doubleValue ?? 0,
    ]
    return [
        "pid": pid,
        "bundleID": bundleID,
        "windowID": windowID.intValue,
        "bounds": rect,
    ]
}

let frontmost = NSWorkspace.shared.frontmostApplication!
let report: [String: Any] = [
    "timestamp": ISO8601DateFormatter().string(from: Date()),
    "frontmostApp": [
        "name": frontmost.localizedName ?? "unknown",
        "bundleID": frontmost.bundleIdentifier ?? "unknown",
        "pid": Int(frontmost.processIdentifier),
    ],
    "mousePosition": ["x": NSEvent.mouseLocation.x, "y": NSEvent.mouseLocation.y],
    "personalAppWindows": selectedWindows,
]

let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8) ?? "{}")
